// 共识 → 自动建包:取 votes 里"多用户 hash 一致(≥K)"的稳定资源,
// 服务端亲自抓字节 + 重算 sha256 校验(不轻信设备报的 hash,防投毒/防已变),
// 通过的写进离线包 + manifest(带 hash),原子替换。产物与 cache-builder 的包同构,复用 bundleVersion 下发。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
const sha256 = (d) => crypto.createHash('sha256').update(d).digest('hex');

// 与设备端 WebCacheManager.fingerprint 完全同算法(DJB2 双哈希 + 长度),用于跨用户共识比对。
// 设备上报的是这个指纹(免在端上算 sha256);服务端抓字节后用同款复算校验。
function fingerprint(buf) {
  let h1 = 5381, h2 = 52711;
  const step = buf.length > 65536 ? 7 : 1; // 与端侧一致:大文件抽样
  for (let i = 0; i < buf.length; i += step) {
    const c = buf[i];
    h1 = ((h1 * 33) ^ c) >>> 0;
    h2 = ((h2 * 33) ^ c) >>> 0;
  }
  return (h1 >>> 0).toString(16) + (h2 >>> 0).toString(16) + '-' + buf.length.toString(16);
}

function extOf(u) {
  const m = u.split('?')[0].match(/\.([a-z0-9]{1,5})$/i);
  return m ? '.' + m[1].toLowerCase() : '';
}
function fileNameFor(u) {
  return sha256(u).slice(0, 32) + extOf(u); // 用 url 指纹做文件名,保证唯一 + 合法(设备按 url 命中,文件名只需唯一)
}
function mimeOf(u) {
  const e = extOf(u);
  const map = { '.js': 'application/javascript', '.mjs': 'application/javascript', '.css': 'text/css',
    '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf', '.otf': 'font/otf',
    '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif',
    '.svg': 'image/svg+xml', '.webp': 'image/webp', '.avif': 'image/avif', '.ico': 'image/x-icon' };
  return map[e] || 'application/octet-stream';
}
function rank(u) {
  const e = extOf(u);
  if (e === '.css') return 1;
  if (e === '.js' || e === '.mjs') return 2;
  if (/^\.(png|jpe?g|gif|svg|webp|avif|ico)$/.test(e)) return 3;
  if (/^\.(woff2?|ttf|otf|eot)$/.test(e)) return 4; // 字体最后,超预算先砍它
  return 9;
}

// 取共识 stable 列表:同一 URL 只有一个 content_hash 且票数 ≥ K(多 hash = 各人不同 = 动态,丢弃)
async function consensusStable(pool, appId, K) {
  const [rows] = await pool.query(
    `SELECT url_hash, content_hash, COUNT(*) AS v, MIN(url) AS url, MIN(mime) AS mime
     FROM votes WHERE app_id=? GROUP BY url_hash, content_hash`, [appId]
  );
  const byUrl = new Map();
  for (const r of rows) {
    let u = byUrl.get(r.url_hash);
    if (!u) { u = { url: r.url, mime: r.mime, variants: 0, top: null }; byUrl.set(r.url_hash, u); }
    u.variants += 1;
    if (!u.top || r.v > u.top.v) u.top = { hash: r.content_hash, v: r.v };
  }
  const out = [];
  for (const u of byUrl.values()) {
    if (u.variants === 1 && u.top && u.top.v >= K) out.push({ url: u.url, mime: u.mime, consensusHash: u.top.hash });
  }
  return out;
}

export async function buildFromConsensus(pool, appCfg, K, BUNDLES_DIR) {
  const appId = appCfg.id;
  const stable = await consensusStable(pool, appId, K);
  stable.sort((a, b) => rank(a.url) - rank(b.url));

  const outDir = path.join(BUNDLES_DIR, appId);
  const tmpDir = outDir + '.tmp';
  fs.rmSync(tmpDir, { recursive: true, force: true });
  fs.mkdirSync(tmpDir, { recursive: true });

  const BUDGET = 5 * 1024 * 1024;
  let total = 0, built = 0, mismatch = 0, failed = 0, skipped = 0;
  const manifest = [];
  for (const e of stable) {
    try {
      const res = await fetch(e.url, { headers: { 'User-Agent': UA } });
      if (!res.ok) { failed++; continue; }
      const buf = Buffer.from(await res.arrayBuffer());
      if (!buf.length) { failed++; continue; }
      const fp = fingerprint(buf);
      if (fp !== e.consensusHash) { mismatch++; continue; } // 服务端复算 djb2 ≠ 用户共识 → 丢弃(投毒/已变)
      if (total + buf.length > BUDGET) { skipped++; continue; }
      const file = fileNameFor(e.url);
      fs.writeFileSync(path.join(tmpDir, file), buf);
      total += buf.length;
      manifest.push({ url: e.url, file, mime: e.mime || mimeOf(e.url), hash: sha256(buf) });
      built++;
    } catch (err) { failed++; }
  }
  fs.writeFileSync(path.join(tmpDir, 'manifest.json'), JSON.stringify(manifest, null, 2), 'utf8');
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.renameSync(tmpDir, outDir);

  return { id: appId, mode: 'consensus', K, stable: stable.length, built, mismatch, failed, skipped, kb: Math.round(total / 1024), builtAt: new Date().toISOString() };
}
