#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_FILE = path.join(__dirname, 'data', 'config.json');
const BUNDLES_DIR = path.join(__dirname, 'bundles');
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';

function mimeOf(u) {
  const p = u.split('?')[0]; // 剥掉版本号 query 再判扩展名
  if (p.endsWith('.js') || p.endsWith('.mjs')) return 'application/javascript';
  if (p.endsWith('.css')) return 'text/css';
  if (p.endsWith('.ttf')) return 'font/ttf';
  if (p.endsWith('.woff2')) return 'font/woff2';
  if (p.endsWith('.woff')) return 'font/woff';
  if (p.endsWith('.otf')) return 'font/otf';
  if (p.endsWith('.html')) return 'text/html';
  return 'application/octet-stream';
}

async function fetchText(url, headers = {}) {
  const r = await fetch(url, { headers: { 'User-Agent': UA, ...headers } });
  return r.ok ? await r.text() : '';
}

function matchAll(text, re) {
  return Array.from(text.matchAll(re)).map((m) => m[0]);
}

function matchGroup(text, re) {
  return Array.from(text.matchAll(re)).map((m) => m[1]).filter(Boolean);
}

// 版本号型 query 识别:query 各参数值全是纯数字(如 ?2025121805、?v=20250117)才算"版本号"。
// 版本号变 = URL 变 = 重新拉,等效内容 hash,缓存安全。排除随机参数(?t=时间戳含字母、?token=xxx)避免缓存爆炸。
// 注:端侧 WebCacheManager.ets 的 isVersionQuery 必须与此完全一致。
function isVersionQuery(query) {
  if (!query || query.length === 0) return false;
  const q = query.charAt(0) === '?' ? query.substring(1) : query;
  if (q.length === 0) return false;
  const parts = q.split('&');
  for (const part of parts) {
    const eq = part.indexOf('=');
    const v = eq >= 0 ? part.substring(eq + 1) : part; // 无 key= 时(如 ?2025121805)取整段
    if (!/^[0-9]+$/.test(v)) return false; // 必须全数字
  }
  return true;
}

// 与 SDK 的 isHashedAsset 一致:认"内容 hash 命名"或"带版本号 query"的不可变静态资源,
// 这样设备端拦截器(shouldCache)才会真正命中并服务,避免打进一堆永远不被用到的资源。
function isHashedAsset(p) {
  const qIdx = p.indexOf('?');
  const query = qIdx >= 0 ? p.substring(qIdx) : '';
  const pathname = qIdx >= 0 ? p.substring(0, qIdx) : p;
  const seg = (pathname.split('/').pop() || '').toLowerCase();
  // sourcemap 仅供调试,设备运行不需要 → 不打进离线包(省体积)
  if (seg.endsWith('.map')) return false;
  const dot = seg.lastIndexOf('.');
  if (dot <= 0) return false;
  if (!/^(js|mjs|css|woff2?|ttf|otf|eot|png|jpe?g|gif|svg|webp|avif|ico)$/.test(seg.slice(dot + 1))) return false;
  // 带版本号 query(纯数字)→ 可缓存(query 变即新 URL,等效 hash)
  if (query && isVersionQuery(query)) return true;
  // 带随机参数(非版本号 query)→ 不缓(避免缓存爆炸)
  if (query) return false;
  // 无 query → 按文件名是否含内容 hash 判断
  return seg.slice(0, dot).split(/[.\-_]/).some((t) => t.length >= 8 && !/^[0-9]+x[0-9]+$/.test(t) && (/^[a-f0-9]+$/.test(t) || (/[0-9]/.test(t) && /[a-z]/.test(t))));
}

function sha256(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function fileNameForPath(u) {
  const p = u.split('?')[0];
  if (p.startsWith('/_next/static/')) return p.slice('/_next/static/'.length).replace(/\//g, '_'); // Next:短名 + 兼容 inferCachedUrl
  return p.replace(/^\//, '').replace(/\//g, '_'); // 通用:整路径转安全文件名(如 dist_..._main.f852479f.chunk.js)
}

function inferCachedUrl(appCfg, file) {
  const origin = new URL(appCfg.url).origin;
  if (file === 'home.html') return origin + '/';
  if (file.startsWith('chunks_')) return origin + '/_next/static/chunks/' + file.slice('chunks_'.length).replace(/_/g, '/');
  if (file.startsWith('css_')) return origin + '/_next/static/css/' + file.slice('css_'.length).replace(/_/g, '/');
  if (file.startsWith('media_')) return origin + '/_next/static/media/' + file.slice('media_'.length).replace(/_/g, '/');
  return '';
}

function readManifestByFile(outDir) {
  const out = new Map();
  const mf = path.join(outDir, 'manifest.json');
  if (!fs.existsSync(mf)) return out;
  try {
    const arr = JSON.parse(fs.readFileSync(mf, 'utf8'));
    if (!Array.isArray(arr)) return out;
    for (const e of arr) {
      if (e && e.file && e.url) out.set(e.file, e);
    }
  } catch {}
  return out;
}

function readManifest(outDir) {
  const mf = path.join(outDir, 'manifest.json');
  if (!fs.existsSync(mf)) return [];
  try {
    const arr = JSON.parse(fs.readFileSync(mf, 'utf8'));
    return Array.isArray(arr) ? arr : [];
  } catch {
    return [];
  }
}

function cacheFileRank(file) {
  if (file === 'home.html') return 0;
  if (file.startsWith('css_') || /\.css$/i.test(file)) return 1;
  if (file.startsWith('chunks_main') || file.startsWith('chunks_webpack') || file.startsWith('chunks_polyfills') || /(^|_)main[.\-_]/i.test(file)) return 2;
  if (file.startsWith('chunks_') || /\.m?js$/i.test(file)) return 3;
  if (file.startsWith('media_') || /\.(woff2?|ttf|otf|eot|png|jpe?g|gif|svg|webp|avif|ico)$/i.test(file)) return 4;
  return 9;
}

// 把 ref(可能是相对/绝对/协议相对/全 URL)解析成同源的 pathname,非同源返回 ''
function sameOriginPath(ref, origin, baseForResolve) {
  try {
    const abs = new URL(ref, baseForResolve);
    if (abs.origin !== origin) return '';
    // 保留版本号型 query(如 ?2025121805)→ 缓存 key 含版本号,版本变即新资源;随机参数仍丢弃
    if (abs.search && isVersionQuery(abs.search)) return abs.pathname + abs.search;
    return abs.pathname;
  } catch {
    return '';
  }
}

async function discoverResources(appCfg) {
  const origin = new URL(appCfg.url).origin;
  const entryUrl = appCfg.url;                                  // 入口页(可为深层子页,如 .../tickets):要缓存的主文档
  const entryU = new URL(entryUrl);
  const entryKey = origin + entryU.pathname + entryU.search;    // 主文档缓存键 = 入口页真实路径(设备端按此 URL 命中)
  const routes = (appCfg.routes && appCfg.routes.length) ? appCfg.routes : ['/'];
  const jsSet = new Set(), cssSet = new Set(), fontSet = new Set();

  const html = await fetchText(entryUrl);
  if (!html) throw new Error('抓取入口页失败');

  // ① Next.js 专用:/_next/static + webpack runtime + 各路由 RSC(对 Next 站抓得最全)
  matchAll(html, /\/_next\/static\/chunks\/[A-Za-z0-9/._-]+\.js/g).forEach((x) => jsSet.add(x));
  matchAll(html, /\/_next\/static\/css\/[A-Za-z0-9._-]+\.css/g).forEach((x) => cssSet.add(x));
  const wp = matchAll(html, /\/_next\/static\/chunks\/webpack-[a-f0-9]+\.js/g)[0];
  if (wp) {
    const wpText = await fetchText(origin + wp);
    matchAll(wpText, /static\/chunks\/[A-Za-z0-9/._-]+\.js/g).forEach((x) => jsSet.add('/_next/' + x));
  }
  for (const r of routes) {
    const rsc = await fetchText(origin + r + '?_rsc=warm', { RSC: '1' });
    matchAll(rsc, /static\/chunks\/[A-Za-z0-9/._-]+\.js/g).forEach((x) => jsSet.add('/_next/' + x));
  }

  // ② 通用:从 <script src> / <link href> 抓同源 hash 静态资源(适配 CRA/Vite/AEM 等非 Next 站)
  const refs = [
    ...matchGroup(html, /<script[^>]+src=["']([^"']+\.js(?:\?[^"']*)?)["']/gi),
    ...matchGroup(html, /<link[^>]+href=["']([^"']+\.css(?:\?[^"']*)?)["']/gi)
  ];
  for (const ref of refs) {
    const p = sameOriginPath(ref, origin, entryUrl);
    if (!p || !isHashedAsset(p)) continue;
    const pathOnly = p.split('?')[0]; // 剥掉版本号 query 再判扩展名(否则 bundle.min.js?2025121805 不以 .js 结尾)
    if (pathOnly.endsWith('.js') || pathOnly.endsWith('.mjs')) jsSet.add(p);
    else if (pathOnly.endsWith('.css')) cssSet.add(p);
  }

  // ③ 从每个 CSS 里抓字体/媒体(Next 的 /_next/static/media + 通用 url() 同源 hash 资源)
  for (const c of cssSet) {
    const css = await fetchText(origin + c);
    matchAll(css, /\/_next\/static\/media\/[A-Za-z0-9/._-]+\.(?:ttf|woff2|woff|otf)/g).forEach((x) => fontSet.add(x));
    for (const m of css.matchAll(/url\(\s*['"]?([^'")?#]+\.(?:woff2|woff|ttf|otf|eot))/gi)) {
      const p = sameOriginPath(m[1], origin, origin + c);
      if (p && isHashedAsset(p)) fontSet.add(p);
    }
  }

  const resources = [
    { url: entryKey, sourceUrl: entryUrl, file: 'home.html', mime: 'text/html' }
  ];
  const all = [...jsSet, ...cssSet, ...fontSet];
  for (const u of all) {
    resources.push({ url: origin + u, sourceUrl: origin + u, file: fileNameForPath(u), mime: mimeOf(u) });
  }

  const seen = new Set();
  const deduped = [];
  for (const r of resources) {
    if (!seen.has(r.url)) {
      seen.add(r.url);
      deduped.push(r);
    }
  }
  deduped.sort((a, b) => {
    const ra = cacheFileRank(a.file), rb = cacheFileRank(b.file);
    return ra === rb ? a.file.localeCompare(b.file) : ra - rb;
  });
  return { html, htmlHash: sha256(html), resources: deduped };
}

function compareDiscovered(appCfg, discovered) {
  const outDir = path.join(BUNDLES_DIR, appCfg.id);
  const oldManifest = readManifest(outDir);
  const oldUrls = new Set(oldManifest.map((e) => e.url).filter(Boolean));
  const nextUrls = new Set(discovered.resources.map((e) => e.url));
  const added = discovered.resources.filter((e) => !oldUrls.has(e.url)).map((e) => e.url);
  const removed = oldManifest.filter((e) => e.url && !nextUrls.has(e.url)).map((e) => e.url);
  const missingFiles = discovered.resources
    .filter((e) => !fs.existsSync(path.join(outDir, e.file)))
    .map((e) => e.file);
  let oldHomeHash = '';
  const homePath = path.join(outDir, 'home.html');
  if (fs.existsSync(homePath)) {
    oldHomeHash = sha256(fs.readFileSync(homePath));
  }
  const homeChanged = oldHomeHash !== discovered.htmlHash;
  return {
    id: appCfg.id,
    mode: 'check',
    changed: homeChanged || added.length > 0 || removed.length > 0 || missingFiles.length > 0,
    homeChanged,
    current: discovered.resources.length,
    cached: oldManifest.length,
    addedCount: added.length,
    removedCount: removed.length,
    missingFileCount: missingFiles.length,
    added: added.slice(0, 20),
    removed: removed.slice(0, 20),
    missingFiles: missingFiles.slice(0, 20),
    checkedAt: new Date().toISOString()
  };
}

async function checkUpdates(appCfg) {
  const discovered = await discoverResources(appCfg);
  return compareDiscovered(appCfg, discovered);
}

function atomicReplace(tmp, target) {
  if (fs.existsSync(target)) fs.rmSync(target, { force: true });
  fs.renameSync(tmp, target);
}

async function downloadResource(entry, outDir) {
  const res = await fetch(entry.sourceUrl, { headers: { 'User-Agent': UA } });
  if (!res.ok) throw new Error(`${res.status} ${entry.sourceUrl}`);
  const buf = Buffer.from(await res.arrayBuffer());
  if (!buf.length) throw new Error(`empty ${entry.sourceUrl}`);
  const target = path.join(outDir, entry.file);
  const tmp = target + '.tmp';
  fs.writeFileSync(tmp, buf);
  atomicReplace(tmp, target);
}

async function updateServerCache(appCfg) {
  const discovered = await discoverResources(appCfg);
  const diff = compareDiscovered(appCfg, discovered);
  const outDir = path.join(BUNDLES_DIR, appCfg.id);
  fs.mkdirSync(outDir, { recursive: true });

  const downloaded = [];
  const skipped = [];
  const failed = [];
  for (const entry of discovered.resources) {
    if (entry.file === 'home.html') continue;
    const target = path.join(outDir, entry.file);
    if (fs.existsSync(target)) {
      skipped.push(entry.file);
      continue;
    }
    try {
      await downloadResource(entry, outDir);
      downloaded.push(entry.file);
    } catch (e) {
      failed.push({ file: entry.file, error: String(e && e.message || e) });
    }
  }
  if (failed.length > 0) {
    throw new Error(`增量更新失败,有 ${failed.length} 个资源未下载: ${failed.slice(0, 3).map((e) => e.file).join(', ')}`);
  }

  const homeTmp = path.join(outDir, 'home.html.tmp');
  fs.writeFileSync(homeTmp, discovered.html, 'utf8');
  const manifest = discovered.resources.map((e) => ({ url: e.url, file: e.file, mime: e.mime }));
  const manifestTmp = path.join(outDir, 'manifest.json.tmp');
  fs.writeFileSync(manifestTmp, JSON.stringify(manifest, null, 2), 'utf8');

  atomicReplace(homeTmp, path.join(outDir, 'home.html'));
  atomicReplace(manifestTmp, path.join(outDir, 'manifest.json'));
  return {
    id: appCfg.id,
    mode: 'incremental-update',
    count: manifest.length,
    changed: diff.changed,
    homeChanged: diff.homeChanged,
    addedCount: diff.addedCount,
    removedCount: diff.removedCount,
    downloaded: downloaded.length,
    skipped: skipped.length,
    builtAt: new Date().toISOString()
  };
}

async function buildServerCache(appCfg) {
  const origin = new URL(appCfg.url).origin;
  const discovered = await discoverResources(appCfg); // 通用发现(Next + CRA/AEM 等)

  const outDir = path.join(BUNDLES_DIR, appCfg.id);
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });

  const manifest = [];
  const homeEntry = discovered.resources.find((e) => e.file === 'home.html');
  fs.writeFileSync(path.join(outDir, 'home.html'), discovered.html, 'utf8');
  // hash:内容指纹,设备据此判断该文件是否需要更新(同 URL 内容变了 → hash 变)
  manifest.push({ url: homeEntry ? homeEntry.url : origin + '/', file: 'home.html', mime: 'text/html', hash: sha256(discovered.html) });

  // 体积上限:资源已按 rank 排序(css/js 在前、字体在后),超预算就跳过 → 砍掉的主要是靠后的字体
  // (字体非首屏关键,文字先用系统字体显示,真正用到时再走运行时缓存)
  const BUDGET = 5 * 1024 * 1024;
  let total = 0, failed = 0, skipped = 0;
  for (const e of discovered.resources) {
    if (e.file === 'home.html') continue;
    try {
      const res = await fetch(e.sourceUrl, { headers: { 'User-Agent': UA } });
      if (!res.ok) { failed++; continue; }
      const len = parseInt(res.headers.get('content-length') || '0', 10);
      if (len > 0 && total + len > BUDGET) { skipped++; try { await res.body?.cancel(); } catch {} continue; }
      const buf = Buffer.from(await res.arrayBuffer());
      if (!buf.length) { failed++; continue; }
      if (total + buf.length > BUDGET) { skipped++; continue; }
      total += buf.length;
      fs.writeFileSync(path.join(outDir, e.file), buf);
      manifest.push({ url: e.url, file: e.file, mime: e.mime, hash: sha256(buf) });
    } catch { failed++; }
  }
  fs.writeFileSync(path.join(outDir, 'manifest.json'), JSON.stringify(manifest, null, 2), 'utf8');
  return { id: appCfg.id, count: manifest.length, discovered: discovered.resources.length, failed, skipped, kb: Math.round(total / 1024), builtAt: new Date().toISOString(), mode: 'server-cache' };
}

function buildCacheManifest(appCfg) {
  const outDir = path.join(BUNDLES_DIR, appCfg.id);
  if (!fs.existsSync(outDir)) {
    throw new Error(`服务器缓存目录不存在: ${outDir}`);
  }
  const previous = readManifestByFile(outDir);
  const files = fs.readdirSync(outDir)
    .filter((f) => f !== 'manifest.json' && fs.statSync(path.join(outDir, f)).isFile())
    .sort((a, b) => {
      const ra = cacheFileRank(a), rb = cacheFileRank(b);
      return ra === rb ? a.localeCompare(b) : ra - rb;
    });
  if (!files.length) {
    throw new Error(`服务器缓存目录没有资源文件: ${outDir}`);
  }
  const manifest = [];
  for (const file of files) {
    const old = previous.get(file);
    const url = old && old.url ? old.url : inferCachedUrl(appCfg, file);
    if (!url) continue;
    manifest.push({ url, file, mime: old && old.mime ? old.mime : mimeOf(file) });
  }
  if (!manifest.length) {
    throw new Error('未能从缓存文件推导出任何原站 URL,请保留旧 manifest 或使用 chunks_/css_/media_/home.html 命名');
  }
  fs.writeFileSync(path.join(outDir, 'manifest.json'), JSON.stringify(manifest, null, 2), 'utf8');
  return { id: appCfg.id, count: manifest.length, builtAt: new Date().toISOString(), mode: 'cache-manifest' };
}

// 探测一个站点:抓首页 HTML → 判框架类型 + 提取名称/图标 + 给加速参数建议。
// 供后台"新增应用一键探测"用,让上架更傻瓜(填 URL 自动带出名称/类型/建议开关)。
export async function detectSite(url) {
  const u = new URL(url);
  const origin = u.origin;
  const html = await fetchText(url);
  if (!html) throw new Error('抓取目标站失败(可能反爬或不可达)');

  // 框架类型
  const isNext = /\/_next\/static\//.test(html) || /__NEXT_DATA__/.test(html);
  const isVite = /type=["']module["'][^>]+src=["'][^"']*\/assets\//.test(html) || /\/@vite\//.test(html);
  const isCRA = /\/static\/js\/main\.[a-f0-9]+\.js/.test(html);
  const appType = isNext ? 'next' : (isVite ? 'vite' : (isCRA ? 'cra' : 'other'));

  // 网站名称:<title> 优先,退化用 og:site_name
  let name = '';
  const tm = html.match(/<title[^>]*>([^<]+)<\/title>/i);
  if (tm) name = tm[1].trim().replace(/\s+/g, ' ').slice(0, 40);
  if (!name) { const og = html.match(/<meta[^>]+property=["']og:site_name["'][^>]+content=["']([^"']+)/i); if (og) name = og[1].trim().slice(0, 40); }

  // 图标:<link rel=icon|apple-touch-icon>
  let icon = '';
  const im = html.match(/<link[^>]+rel=["'][^"']*icon[^"']*["'][^>]+href=["']([^"']+)/i);
  if (im) { try { icon = new URL(im[1], origin).href; } catch {} }

  // 同源静态资源数(粗估,判断离线包是否值得做)
  const refs = [
    ...matchGroup(html, /<script[^>]+src=["']([^"']+\.js(?:\?[^"']*)?)["']/gi),
    ...matchGroup(html, /<link[^>]+href=["']([^"']+\.css(?:\?[^"']*)?)["']/gi)
  ];
  let sameOriginCacheable = 0;
  for (const ref of refs) {
    const p = sameOriginPath(ref, origin, url);
    if (p && isHashedAsset(p)) sameOriginCacheable++;
  }

  // 预连接域建议:从页面引用的资源里提取"跨域"域名(和主域不同的 host)= 该站的 CDN/接口域。
  // 开机对这些域提前 DNS+TLS 握手,点进去时资源直连不等握手,压短白屏(尤其 JS 渲染型站主文档空、资源全在跨域CDN)。
  const allRefs = [
    ...matchGroup(html, /<script[^>]+src=["']([^"']+)["']/gi),
    ...matchGroup(html, /<link[^>]+href=["']([^"']+)["']/gi),
    ...matchGroup(html, /<img[^>]+src=["']([^"']+)["']/gi),
    ...matchGroup(html, /(?:href|src|content)=["'](https?:\/\/[^"']+)["']/gi),
  ];
  const mainHost = u.host;
  const crossHosts = new Set();
  for (const ref of allRefs) {
    try {
      const h = new URL(ref, origin).host;
      // 只收和主域不同、且非纯统计/广告的域 = 该站的 CDN/接口域
      if (h && h !== mainHost && !/(google-analytics|googletagmanager|doubleclick|facebook|hotjar|sentry)\./i.test(h)) {
        crossHosts.add(h);
      }
    } catch {}
  }
  const preconnectHosts = [...crossHosts].slice(0, 12); // 最多 12 个,避免预连过多反占资源

  // 加速参数建议:动态 SPA 一律 swrDoc+prerender;有同源可缓资源才建议 bundle;Next 站开 codeCache+prefetch
  const recommend = {
    swrDoc: true,
    prerender: true,
    bundle: sameOriginCacheable > 0,
    codeCache: isNext,
    prefetchChunks: isNext, // chunk 预取目前只对 Next/webpack 有效
    preconnectHosts, // 探测到的跨域CDN/接口域,建议预连接
  };

  return { ok: true, url, origin, appType, name, icon, sameOriginCacheable, preconnectHosts, recommend };
}

function appFromArg(raw) {
  if (!raw) throw new Error('缺少 appId 或 app 配置 JSON');
  const text = String(raw).trim();
  if (text.startsWith('{')) {
    const parsed = JSON.parse(text);
    if (!parsed || !parsed.id || !parsed.url) throw new Error('app 配置缺少 id 或 url');
    return parsed;
  }
  const cfg = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
  const app = (cfg.apps || []).find((a) => a.id === text);
  if (!app) throw new Error(`app not found: ${text}`);
  return app;
}

async function main() {
  const mode = process.argv[2];
  const appCfg = appFromArg(process.argv[3]);
  if (mode === 'check') {
    return checkUpdates(appCfg);
  }
  if (mode === 'update') {
    return updateServerCache(appCfg);
  }
  if (mode === 'build') {
    return buildServerCache(appCfg);
  }
  if (mode === 'manifest') {
    return buildCacheManifest(appCfg);
  }
  throw new Error(`未知模式: ${mode}`);
}

// 只在【直接命令行运行】时执行 main();被 index.js import(用 detectSite)时不执行,避免误读 argv。
const isDirectRun = process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);
if (isDirectRun) {
  main()
    .then((result) => {
      process.stdout.write(JSON.stringify({ ok: true, result }) + '\n');
    })
    .catch((err) => {
      process.stderr.write(String(err && err.stack || err) + '\n');
      process.stdout.write(JSON.stringify({ ok: false, error: String(err && err.message || err) }) + '\n');
      process.exit(1);
    });
}
