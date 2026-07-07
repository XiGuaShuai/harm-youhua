// 鸿蒙网页加速方案 —— 远程配置 + 离线包服务端 (Express, Node 18+)
//
// 提供:
//  1) GET /api/config        —— 鸿蒙 App 开机拉取(应用列表 + 黑名单 + 全局设置 + 离线包地址)
//  2) /bundles/*             —— 托管离线包(manifest.json + 资源文件),App 从这里快速拉取
//  3) /api/admin/*           —— 后台管理(增删改应用、黑名单、设置;构建服务器缓存/生成缓存清单)
//
// 配置持久化:data/config.json(纯文件,无需数据库)

import express from 'express';
import cors from 'cors';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { initDb, dbReady, getPool } from './db.js';
import { buildFromConsensus } from './consensus-builder.js';
import { detectSite } from './cache-builder.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_FILE = path.join(__dirname, 'data', 'config.json');
const USERS_FILE = path.join(__dirname, 'data', 'users.json');
const SESSIONS_FILE = path.join(__dirname, 'data', 'sessions.json');
const BUNDLES_DIR = path.join(__dirname, 'bundles');
const CACHE_BUILDER = path.join(__dirname, 'cache-builder.js');
// 管理界面构建产物(admin/web/dist);容器内由 Dockerfile 置于 /app/web/dist 并用 WEB_DIST 指定
const WEB_DIST = process.env.WEB_DIST || path.join(__dirname, '..', 'web', 'dist');
const PORT = process.env.PORT || 8787;
const FETCH_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
const IMPORT_TIMEOUT_MS = 60 * 1000;
// 可选「主令牌」:仅当显式设置 ADMIN_TOKEN 时生效(给脚本/CI 用),默认不开,走账号密码登录
const MASTER_TOKEN = process.env.ADMIN_TOKEN || '';
const DEFAULT_USER = process.env.ADMIN_USER || 'admin';
const DEFAULT_PASS = process.env.ADMIN_PASS || 'admin123';
const SESSION_TTL_MS = 7 * 24 * 3600 * 1000; // 登录态有效期 7 天

fs.mkdirSync(path.dirname(DATA_FILE), { recursive: true });
fs.mkdirSync(BUNDLES_DIR, { recursive: true });

// ——————————————— 账号 / 密码 / 会话 ———————————————
// 密码用 scrypt 加盐哈希,存 data/users.json;会话 token 存 data/sessions.json(重启不掉线)
function hashPassword(pw, salt = crypto.randomBytes(16).toString('hex')) {
  const dk = crypto.scryptSync(String(pw), salt, 64).toString('hex');
  return `${salt}:${dk}`;
}
function verifyPassword(pw, stored) {
  const [salt, dk] = String(stored || '').split(':');
  if (!salt || !dk) return false;
  const test = crypto.scryptSync(String(pw), salt, 64).toString('hex');
  const a = Buffer.from(dk, 'hex'), b = Buffer.from(test, 'hex');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
function loadUsers() {
  try { return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8')); }
  catch {
    const u = [{ username: DEFAULT_USER, password: hashPassword(DEFAULT_PASS), createdAt: new Date().toISOString() }];
    saveUsers(u);
    return u;
  }
}
function saveUsers(u) { fs.writeFileSync(USERS_FILE, JSON.stringify(u, null, 2), 'utf8'); }

let sessions = {};
(function loadSessions() {
  try { sessions = JSON.parse(fs.readFileSync(SESSIONS_FILE, 'utf8')); } catch { sessions = {}; }
  pruneSessions();
})();
function saveSessions() { fs.writeFileSync(SESSIONS_FILE, JSON.stringify(sessions), 'utf8'); }
function pruneSessions() {
  const now = Date.now(); let changed = false;
  for (const t of Object.keys(sessions)) if (sessions[t].expires < now) { delete sessions[t]; changed = true; }
  if (changed) saveSessions();
}
function createSession(username) {
  const token = crypto.randomBytes(24).toString('hex');
  sessions[token] = { username, expires: Date.now() + SESSION_TTL_MS };
  saveSessions();
  return token;
}
function sessionUser(token) {
  const s = sessions[token];
  if (!s) return null;
  if (s.expires < Date.now()) { delete sessions[token]; saveSessions(); return null; }
  return s.username;
}
if (!fs.existsSync(USERS_FILE)) loadUsers(); // 首次启动落地默认账号

// ——————————————— 配置读写 ———————————————
function defaultConfig() {
  return {
    version: new Date().toISOString(),
    apps: [
      {
        id: 'beacukai',
        name: '印尼海关 e-CD',
        url: 'https://ecd.beacukai.go.id/',
        routes: ['/', '/forms/bc22', '/forms/bc32', '/forms/bc34'],
        swrDoc: true,        // 主文档陈旧即用缓存
        prerender: true,     // 离屏预渲染
        codeCache: true,     // JS 字节码缓存
        bundle: true         // 是否启用离线包(从本服务器拉)
      },
      {
        id: 'rwsentosa',
        name: '圣淘沙名胜世界 RWS',
        url: 'https://www.rwsentosa.com/',
        swrDoc: true,        // 首页陈旧即用缓存
        prerender: true,     // 离屏预渲染→秒开(有离线包后从本地取资源,预渲染快、不再抢 beacukai 带宽)
        codeCache: false,    // 元服务不支持字节码注入
        bundle: true         // 通用化 cache-builder 已能给非 Next 站(CRA/AEM)打离线包(5MB 上限,字体超量走运行时)
      }
    ],
    // 通用过滤黑名单:被墙/纯追踪的第三方,App 端命中即秒拒(屏蔽后不影响功能)
    blockHosts: [
      'translate.google', 'translate.googleapis', 'gstatic.com/_/translate', 'gstatic.com/translate',
      'google-analytics.com', 'googletagmanager.com', 'googletagservices.com', 'analytics.google.com', 'googleadservices.com',
      'doubleclick.net', 'googlesyndication.com', 'adservice.google',
      'connect.facebook.net', 'facebook.com/tr', 'platform.twitter.com',
      'fonts.googleapis.com', 'fonts.gstatic.com',
      'hotjar.com', 'mixpanel.com', 'fullstory.com', 'clarity.ms',
      // —— rwsentosa(USS 购票流程)实测追加的广告/数据/追踪域(屏蔽后购票功能不受影响)——
      'adform.net', 'adsrvr.org', 'pubmatic.com', 'openx.net', 'adnxs.com',
      'dotomi.com', 'crwdcntrl.net', 'eyeota.net', 'stackadapt.com', 'sojern.com',
      'analytics.tiktok.com', 'bat.bing.com', 'px.ads.linkedin.com', 'snap.licdn.com',
      'conviva.com', 's4mdsp.com', 'ad.daum.net', 's.yimg.com',
      'aem-kakao-collector.onkakao.net', 'aichat.com'
    ],
    settings: {
      diskCapMB: 160,        // 运行时缓存上限(按 200MB 沙箱预留余量)
      docCheckSec: 60,       // 主文档版本校验节流(秒)
      bundleConcurrency: 8,  // 远程离线包后台下载并发(上限 8)
      prefetchChunks: true,  // 是否预取全站 chunk(Next.js 系有效)
      bytecodeCache: true,
      autoUpdate: true,
      exploreK: 3,           // 众包共识阈值:≥K 个用户 hash 一致才采纳为可缓存
      exploreSample: 0.1     // 探索采样率:命中待探索名单的 app,每次打开按此概率上报(0.1=10%,减负)
    }
  };
}
function loadConfig() {
  try { return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); }
  catch { const c = defaultConfig(); saveConfig(c); return c; }
}
function saveConfig(c) {
  c.version = new Date().toISOString();
  fs.writeFileSync(DATA_FILE, JSON.stringify(c, null, 2), 'utf8');
  return c;
}
if (!fs.existsSync(DATA_FILE)) saveConfig(defaultConfig());

// ——————————————— 缓存构建程序触发 ———————————————
function runCacheBuilder(mode, appId) {
  return new Promise((resolve, reject) => {
    execFile(process.execPath, [CACHE_BUILDER, mode, appId], {
      cwd: __dirname,
      windowsHide: true,
      timeout: 10 * 60 * 1000,
      maxBuffer: 10 * 1024 * 1024
    }, (err, stdout, stderr) => {
      let parsed = null;
      const lines = String(stdout || '').trim().split(/\r?\n/).filter(Boolean);
      if (lines.length) {
        try { parsed = JSON.parse(lines[lines.length - 1]); } catch {}
      }
      if (err || !parsed || parsed.ok !== true) {
        const msg = parsed && parsed.error ? parsed.error : (stderr || err && err.message || 'cache builder failed');
        reject(new Error(String(msg).trim()));
        return;
      }
      resolve(parsed.result);
    });
  });
}

// ——————————————— 定时自动更新离线包(一天一次)的配置 ———————————————
// 每天自动遍历所有 bundle:true 的站:check 看源站有没有更新 → 有更新就 update(增量),
// update 失败自动 fallback 到 build(全量重建),build 失败重试。一个站失败不影响其它站。
// 结果写 data/auto-update-log.json,后台可查"上次自动更新时间/结果"。函数定义见文件末尾(会提升)。
const AUTO_UPDATE_INTERVAL_MS = 24 * 60 * 60 * 1000; // 一天一次
const AUTO_UPDATE_FIRST_DELAY_MS = 60 * 1000;        // 服务启动 1 分钟后先跑一次
const AUTO_UPDATE_LOG = path.join(__dirname, 'data', 'auto-update-log.json');
let autoUpdateRunning = false;

// ——————————————— Express ———————————————
const app = express();
app.use(cors());
app.use(express.json({ limit: '4mb' }));

// 同源托管管理界面(admin/web 构建产物):静态资源命中即返回,未命中则交给后续路由。
// 本地用 vite(5174)代理调试时 WEB_DIST 不存在,此块自动跳过,不影响开发流程。
if (fs.existsSync(WEB_DIST)) app.use(express.static(WEB_DIST));

// 鸿蒙 App 开机拉取(公开)
// 对启用离线包且服务端已有缓存清单的 app,附上 manifestUrl —— App 据此去服务器下载缓存资源
app.get('/api/config', (req, res) => {
  const c = loadConfig();
  const apps = (c.apps || []).map((a) => {
    const mfPath = path.join(BUNDLES_DIR, a.id, 'manifest.json');
    const compressedMfPath = path.join(BUNDLES_DIR, a.id, 'manifest.zz.json');
    const hasBundle = fs.existsSync(mfPath);
    if (a.bundle && hasBundle) {
      // bundleVersion = 清单内容指纹:清单一变(资源增删改)它就变,设备据此判断"要不要更新离线包"
      let bundleVersion = '';
      let compressedBundleVersion = '';
      try { bundleVersion = crypto.createHash('sha256').update(fs.readFileSync(mfPath)).digest('hex').slice(0, 16); } catch {}
      const extra = { manifestUrl: `/bundles/${a.id}/manifest.json`, bundleVersion };
      if (fs.existsSync(compressedMfPath)) {
        try {
          compressedBundleVersion = crypto.createHash('sha256').update(fs.readFileSync(compressedMfPath)).digest('hex').slice(0, 16);
        } catch {}
        Object.assign(extra, {
          compressedManifestUrl: `/bundles/${a.id}/manifest.zz.json`,
          compressedBundleVersion
        });
      }
      return Object.assign({}, a, extra);
    }
    return a;
  });
  // 任务派发:把"待探索清单 + 共识阈值 K + 采样率"下发给设备(设备只对名单内 app 按采样率上报)
  const s = c.settings || {};
  const explore = {
    apps: (c.apps || []).filter((a) => a.explore).map((a) => a.id), // 后台给某 app 设 explore:true 即入列
    k: s.exploreK || 3,
    sample: typeof s.exploreSample === 'number' ? s.exploreSample : 0.1
  };
  res.json(Object.assign({}, c, { apps, explore }));
});

// 离线包静态托管:App 从 /bundles/<id>/manifest.json 拉取
app.use('/bundles', express.static(BUNDLES_DIR));

// ——————————————— 众包上报(设备探索结果)———————————————
// 设备打开某 app 时,把加载到的静态资源 {url, hash, mime, size} 报上来(公开接口,带限频/校验)。
// 一人一票存 votes;多用户对同一 URL 的 hash 一致 = 稳定可缓存(共识)。只收配置内 app,不收 PII。
const reportLimit = new Map(); // key=appId|anonId -> 上次上报时刻(同一设备同一 app 60s 限一次)
app.post('/api/report', async (req, res) => {
  if (!dbReady() || !getPool()) return res.status(503).json({ ok: false, error: 'db not ready' });
  const body = req.body || {};
  const appId = String(body.appId || '');
  const anonId = String(body.anonId || '').slice(0, 64);
  const resources = Array.isArray(body.resources) ? body.resources : [];
  if (!appId || !anonId || resources.length === 0) return res.status(400).json({ ok: false, error: 'bad request' });
  if (!(loadConfig().apps || []).some((a) => a.id === appId)) return res.status(404).json({ ok: false, error: 'unknown app' });
  const key = `${appId}|${anonId}`;
  const now = Date.now();
  if (now - (reportLimit.get(key) || 0) < 60 * 1000) return res.status(429).json({ ok: false, error: 'too frequent' });
  reportLimit.set(key, now);
  const pool = getPool();
  let accepted = 0;
  for (const r of resources.slice(0, 200)) { // 单次最多 200 条
    const url = String(r && r.url || '');
    const hash = String(r && r.hash || '').toLowerCase();
    if (!/^https?:\/\//.test(url) || !/^[a-f0-9-]{8,160}$/.test(hash)) continue; // 只收 http(s) + 合法指纹(sha256 或设备 djb2)
    const urlHash = crypto.createHash('sha256').update(url).digest('hex');
    const mime = r && r.mime ? String(r.mime).slice(0, 128) : null;
    const size = r && Number.isFinite(r.size) ? Math.floor(r.size) : null;
    try {
      await pool.query(
        `INSERT INTO votes (app_id, url_hash, anon_id, content_hash, url, mime, size, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON DUPLICATE KEY UPDATE content_hash=VALUES(content_hash), url=VALUES(url), mime=VALUES(mime), size=VALUES(size), updated_at=VALUES(updated_at)`,
        [appId, urlHash, anonId, hash, url, mime, size, now]
      );
      accepted++;
    } catch (e) { /* 跳过坏行 */ }
  }
  res.json({ ok: true, accepted });
});

// ——————————————— 端侧报错 → 后台离线包自愈 ———————————————
// 端侧发现"离线包登记的资源实际读不出/坏了"时上报这里,后端立即重建该站离线包(自愈),
// 不用等每天一次的定时检查。带防抖:同一站 5 分钟内只重建一次,避免大量上报打爆服务器。
const selfHealLast = new Map();      // appId -> 上次自愈重建时刻
const SELF_HEAL_COOLDOWN_MS = 5 * 60 * 1000;
app.post('/api/report-error', (req, res) => {
  const body = req.body || {};
  const appId = String(body.appId || '').trim();
  const reason = String(body.reason || 'bundle-resource-missing').slice(0, 64);
  if (!appId) return res.status(400).json({ ok: false, error: 'bad request' });
  // 只对"配了离线包(bundle:true)"的站做自愈;动态站/未配离线包的站忽略(它们本就没离线包,无所谓坏)
  const app0 = (loadConfig().apps || []).find((a) => a.id === appId);
  if (!app0) return res.status(404).json({ ok: false, error: 'unknown app' });
  if (app0.bundle !== true) return res.json({ ok: true, action: 'ignored', detail: '该站未配离线包,无需自愈' });
  const now = Date.now();
  const last = selfHealLast.get(appId) || 0;
  if (now - last < SELF_HEAL_COOLDOWN_MS) {
    return res.json({ ok: true, action: 'cooldown', detail: '近期已自愈,本次跳过' });
  }
  selfHealLast.set(appId, now);
  // 异步重建,立即返回(不阻塞端侧)
  (async () => {
    try {
      console.log(`[self-heal] ${appId} 端侧报错(${reason}) → 立即重建离线包...`);
      const bd = await buildWithRetry(appId);
      console.log(`[self-heal] ${appId} 重建完成: ${bd && bd.count || 0} 个资源`);
    } catch (e) {
      console.warn(`[self-heal] ${appId} 重建失败:`, e && e.message);
    }
  })();
  res.json({ ok: true, action: 'rebuilding', detail: '已触发离线包重建' });
});

// 登录:账号 + 密码 → 颁发会话 token
app.post('/api/login', (req, res) => {
  const { username, password } = req.body || {};
  const u = loadUsers().find((x) => x.username === username);
  if (!u || !verifyPassword(password, u.password)) {
    return res.status(401).json({ ok: false, error: '账号或密码不正确' });
  }
  res.json({ ok: true, token: createSession(username), username });
});

// 退出:作废当前会话 token
app.post('/api/logout', (req, res) => {
  const t = tokenOf(req);
  if (t && sessions[t]) { delete sessions[t]; saveSessions(); }
  res.json({ ok: true });
});

// 从请求里取 token(优先 X-Admin-Token,兼容 Authorization: Bearer)
function tokenOf(req) {
  return req.headers['x-admin-token'] || String(req.headers.authorization || '').replace(/^Bearer\s+/i, '');
}

// 后台鉴权:会话 token 或(显式开启的)主令牌
function auth(req, res, next) {
  const t = tokenOf(req);
  if (MASTER_TOKEN && t === MASTER_TOKEN) { req.user = DEFAULT_USER; return next(); }
  const user = sessionUser(t);
  if (!user) return res.status(401).json({ error: 'unauthorized' });
  req.user = user;
  next();
}
app.use('/api/admin', auth);

// 当前登录用户
app.get('/api/admin/me', (req, res) => res.json({ username: req.user }));

// DB(MySQL)状态:联调验证用 —— 连上没、votes 表多少行
app.get('/api/admin/db', async (req, res) => {
  if (!dbReady() || !getPool()) return res.json({ ready: false });
  try {
    const [rows] = await getPool().query('SELECT COUNT(*) AS n FROM votes');
    res.json({ ready: true, votes: rows[0].n });
  } catch (e) {
    res.json({ ready: false, error: String(e && e.message || e) });
  }
});

// 共识:某 app 下,哪些 URL 被多用户报成同一 hash(≥K)= 稳定可缓存;
// 同一 URL 出现多个 hash = 用户间不一致 = 动态,不缓存。?k=2 设阈值。
app.get('/api/admin/report/:id', async (req, res) => {
  if (!dbReady() || !getPool()) return res.status(503).json({ error: 'db not ready' });
  const appId = req.params.id;
  const K = Math.max(1, parseInt(req.query.k || '2', 10));
  try {
    const [rows] = await getPool().query(
      `SELECT url_hash, content_hash, COUNT(*) AS votes, MIN(url) AS url, MIN(mime) AS mime, MAX(size) AS size
       FROM votes WHERE app_id=? GROUP BY url_hash, content_hash`, [appId]
    );
    const byUrl = new Map();
    for (const r of rows) {
      let u = byUrl.get(r.url_hash);
      if (!u) { u = { url: r.url, mime: r.mime, size: r.size, variants: 0, topHash: null, topVotes: 0 }; byUrl.set(r.url_hash, u); }
      u.variants += 1;
      if (r.votes > u.topVotes) { u.topVotes = r.votes; u.topHash = r.content_hash; u.size = r.size; }
    }
    const stable = [], unstable = [];
    for (const u of byUrl.values()) {
      // 稳定 = 只有一个 hash 且票数 ≥ K(多 hash 说明各人内容不同 → 动态)
      if (u.variants === 1 && u.topVotes >= K) stable.push({ url: u.url, mime: u.mime, size: u.size, hash: u.topHash, votes: u.topVotes });
      else unstable.push({ url: u.url, variants: u.variants, votes: u.topVotes });
    }
    res.json({ appId, K, totalUrls: byUrl.size, stableCount: stable.length, unstableCount: unstable.length, stable: stable.slice(0, 100), unstable: unstable.slice(0, 50) });
  } catch (e) {
    res.status(500).json({ error: String(e && e.message || e) });
  }
});

// 按共识建包:取 stable 资源 → 服务端抓字节 + 重算 hash 校验 → 写离线包 + manifest(带 hash)。?k=N 设阈值。
app.post('/api/admin/report/:id/build', async (req, res) => {
  if (!dbReady() || !getPool()) return res.status(503).json({ error: 'db not ready' });
  const appCfg = (loadConfig().apps || []).find((a) => a.id === req.params.id);
  if (!appCfg) return res.status(404).json({ error: 'app not found' });
  const K = Math.max(1, parseInt(req.query.k || '2', 10));
  try {
    const r = await buildFromConsensus(getPool(), appCfg, K, BUNDLES_DIR);
    res.json(r);
  } catch (e) {
    res.status(500).json({ error: String(e && e.message || e) });
  }
});

// 修改密码
app.post('/api/admin/password', (req, res) => {
  const { oldPassword, newPassword } = req.body || {};
  if (!newPassword || String(newPassword).length < 6) return res.status(400).json({ error: '新密码至少 6 位' });
  const users = loadUsers();
  const u = users.find((x) => x.username === req.user);
  if (!u) return res.status(404).json({ error: '用户不存在' });
  if (!verifyPassword(oldPassword, u.password)) return res.status(400).json({ error: '原密码不正确' });
  u.password = hashPassword(newPassword);
  u.updatedAt = new Date().toISOString();
  saveUsers(users);
  res.json({ ok: true });
});

app.get('/api/admin/config', (req, res) => res.json(loadConfig()));
app.put('/api/admin/apps', (req, res) => {
  const c = loadConfig();
  const nextApps = req.body.apps || [];
  // 保存前先算出"需要自动构建离线包"的站:bundle:true 且服务器上还没有离线包(manifest 不存在)。
  // 这样后台加一个新静态站(或把某站改成 bundle:true)保存后,离线包会自动在后台建好,
  // 用户第一次进入就能直接从离线包加载(首屏即快),不用再手动去 Bundles 页点构建。
  const autoBuildIds = nextApps
    .filter(a => a && a.id && a.bundle === true)
    .filter(a => !fs.existsSync(path.join(BUNDLES_DIR, a.id, 'manifest.json')))
    .map(a => a.id);
  c.apps = nextApps;
  const saved = saveConfig(c);
  // 异步触发构建,不阻塞保存响应(构建可能要几十秒~几分钟)。逐个串行,避免并发抢网络。
  if (autoBuildIds.length) {
    (async () => {
      for (const id of autoBuildIds) {
        try {
          console.log(`[auto-build] 新静态站 ${id}: 自动构建离线包...`);
          await runCacheBuilder('build', id);
          console.log(`[auto-build] ${id} 离线包构建完成`);
        } catch (e) {
          console.warn(`[auto-build] ${id} 构建失败(可去 Bundles 页手动重试):`, e && e.message);
        }
      }
    })();
  }
  res.json(Object.assign({}, saved, { autoBuilding: autoBuildIds }));
});
// 立即手动触发一次"自动检查更新所有站"(后台按钮用);异步执行,立即返回
app.post('/api/admin/auto-update/run', (req, res) => {
  runAutoUpdateOnce('manual').catch(() => {});
  res.json({ ok: true, message: '已触发自动检查更新(后台执行中,稍后查结果)' });
});
// 查上次自动更新结果
app.get('/api/admin/auto-update/log', (req, res) => {
  try {
    const log = JSON.parse(fs.readFileSync(AUTO_UPDATE_LOG, 'utf8'));
    res.json({ ok: true, running: autoUpdateRunning, log });
  } catch {
    res.json({ ok: true, running: autoUpdateRunning, log: null });
  }
});

// 一键探测站点:填 URL → 自动返回 名称/类型/图标/建议加速参数,让新增应用更傻瓜。
app.post('/api/admin/apps/detect', async (req, res) => {
  const url = String((req.body && req.body.url) || '').trim();
  if (!/^https?:\/\//.test(url)) return res.status(400).json({ ok: false, error: '请填写 http(s):// 开头的完整 URL' });
  try {
    const r = await detectSite(url);
    res.json(r);
  } catch (e) {
    res.status(502).json({ ok: false, error: String(e && e.message || e) });
  }
});
app.put('/api/admin/blockhosts', (req, res) => {
  const c = loadConfig(); c.blockHosts = req.body.blockHosts || []; res.json(saveConfig(c));
});
app.put('/api/admin/settings', (req, res) => {
  const c = loadConfig(); c.settings = req.body.settings || {}; res.json(saveConfig(c));
});

function readJsonArray(file) {
  try {
    const arr = JSON.parse(fs.readFileSync(file, 'utf8'));
    return Array.isArray(arr) ? arr : [];
  } catch {
    return [];
  }
}

function safeBundlePath(dir, file) {
  const root = path.resolve(dir);
  const p = path.resolve(dir, String(file || ''));
  if (p !== root && p.startsWith(root + path.sep)) return p;
  return '';
}

function isCompressibleResource(mime, file) {
  const m = String(mime || '').toLowerCase();
  const f = String(file || '').toLowerCase();
  return m.startsWith('text/') ||
    m.includes('javascript') ||
    m.includes('json') ||
    m.includes('xml') ||
    f.endsWith('.js') ||
    f.endsWith('.mjs') ||
    f.endsWith('.css') ||
    f.endsWith('.html') ||
    f.endsWith('.svg');
}

function compressionEstimate(buf) {
  try {
    const gzip = zlib.gzipSync(buf, { level: 6 }).length;
    const br = zlib.brotliCompressSync(buf, {
      params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 5 }
    }).length;
    return { gzip, br };
  } catch {
    return { gzip: 0, br: 0 };
  }
}

function mimeOfPath(u) {
  const p = String(u || '').split('?')[0].toLowerCase();
  if (p.endsWith('.js') || p.endsWith('.mjs')) return 'application/javascript';
  if (p.endsWith('.css')) return 'text/css';
  if (p.endsWith('.html')) return 'text/html';
  if (p.endsWith('.png')) return 'image/png';
  if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
  if (p.endsWith('.webp')) return 'image/webp';
  if (p.endsWith('.avif')) return 'image/avif';
  if (p.endsWith('.gif')) return 'image/gif';
  if (p.endsWith('.svg')) return 'image/svg+xml';
  if (p.endsWith('.woff2')) return 'font/woff2';
  if (p.endsWith('.woff')) return 'font/woff';
  if (p.endsWith('.ttf')) return 'font/ttf';
  if (p.endsWith('.otf')) return 'font/otf';
  return 'application/octet-stream';
}

function appendUrlHash(name, u) {
  if (!String(u || '').includes('?')) return name;
  const hash = crypto.createHash('sha1').update(String(u || '')).digest('hex').slice(0, 8);
  const ext = path.extname(name);
  if (!ext) return `${name}_${hash}`;
  return `${name.slice(0, -ext.length)}_${hash}${ext}`;
}

function fileNameForUrl(u) {
  let p = String(u || '').split('?')[0];
  let hasQuery = String(u || '').includes('?');
  try {
    const parsed = new URL(u);
    p = parsed.host + parsed.pathname;
    hasQuery = !!parsed.search;
  } catch {}
  const name = p.startsWith('/_next/static/')
    ? p.slice('/_next/static/'.length).replace(/\//g, '_')
    : p.replace(/^\//, '').replace(/[^A-Za-z0-9._-]+/g, '_');
  return hasQuery ? appendUrlHash(name, u) : name;
}

function parseImportUrls(body, appCfg) {
  return parseImportResources(body, appCfg).map((r) => r.url);
}

function parseImportResources(body, appCfg) {
  const raw = [];
  if (Array.isArray(body && body.urls)) raw.push(...body.urls.map((url) => ({ url })));
  if (Array.isArray(body && body.resources)) {
    raw.push(...body.resources.map((r) => typeof r === 'string' ? { url: r } : r));
  }
  const text = String(body && body.text || '');
  if (text) raw.push(...text.split(/[\r\n\t ]+/).map((url) => ({ url })));

  const out = [];
  const seen = new Set();
  for (const item of raw) {
    const rawUrl = typeof item === 'string' ? item : item && item.url;
    const cleaned = String(rawUrl || '').trim().replace(/^[<"'`]+|[>"'`,;]+$/g, '');
    if (!cleaned) continue;
    try {
      const u = new URL(cleaned, appCfg.url);
      if (u.protocol !== 'http:' && u.protocol !== 'https:') continue;
      const href = u.href;
      if (!seen.has(href)) {
        seen.add(href);
        const size = Number(item && item.size);
        const costMs = Number(item && item.costMs);
        out.push({
          url: href,
          size: Number.isFinite(size) && size > 0 ? size : 0,
          costMs: Number.isFinite(costMs) && costMs > 0 ? costMs : 0,
          source: String(item && item.source || '').trim()
        });
      }
    } catch {}
  }
  return out;
}

function headerMime(res, url) {
  const ct = String(res.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
  return ct || mimeOfPath(url);
}

async function downloadImportResource(input, appCfg, dir, maxResourceBytes) {
  const url = typeof input === 'string' ? input : String(input && input.url || '');
  const measuredSize = Number(input && input.size || 0);
  const started = Date.now();
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), IMPORT_TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      redirect: 'follow',
      signal: ctrl.signal,
      headers: {
        'User-Agent': appCfg.userAgent || FETCH_UA,
        'Accept': '*/*'
      }
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const len = parseInt(res.headers.get('content-length') || '0', 10);
    if (maxResourceBytes > 0 && len > maxResourceBytes) {
      try { await res.body?.cancel(); } catch {}
      throw new Error(`文件超过导入上限 ${Math.round(maxResourceBytes / 1024)}KB`);
    }
    const buf = Buffer.from(await res.arrayBuffer());
    if (!buf.length) throw new Error('empty response');
    if (measuredSize >= 64 * 1024 && buf.length < measuredSize * 0.5) {
      throw new Error(`downloaded size ${buf.length}B is much smaller than device measured ${measuredSize}B`);
    }
    if (maxResourceBytes > 0 && buf.length > maxResourceBytes) {
      throw new Error(`文件超过导入上限 ${Math.round(maxResourceBytes / 1024)}KB`);
    }
    const file = fileNameForUrl(url);
    const target = safeBundlePath(dir, file);
    if (!target) throw new Error('bad target file');
    fs.writeFileSync(target, buf);
    const mime = headerMime(res, url);
    return {
      ok: true,
      url,
      file,
      mime,
      size: buf.length,
      sizeKB: Math.round(buf.length / 102.4) / 10,
      hash: crypto.createHash('sha256').update(buf).digest('hex'),
      costMs: Date.now() - started
    };
  } finally {
    clearTimeout(timer);
  }
}

function matchesPattern(url, pattern) {
  if (!pattern) return false;
  const u = String(url).toLowerCase();
  const p = String(pattern).toLowerCase();
  if (!p.includes('*')) return u.includes(p);
  const parts = p.split('*').filter(Boolean);
  if (!parts.length) return true;
  if (!p.startsWith('*') && !u.startsWith(parts[0])) return false;
  let pos = 0;
  for (const part of parts) {
    const idx = u.indexOf(part, pos);
    if (idx < 0) return false;
    pos = idx + part.length;
  }
  if (!p.endsWith('*') && !u.endsWith(parts[parts.length - 1])) return false;
  return true;
}

function matchesAny(url, patterns) {
  return Array.isArray(patterns) && patterns.some((p) => matchesPattern(url, p));
}

function bundleInfo(id, appCfg) {
  const dir = path.join(BUNDLES_DIR, id);
  const mf = path.join(dir, 'manifest.json');
  if (!fs.existsSync(mf)) return null;
  const stat = fs.statSync(mf);
  const manifest = readJsonArray(mf);
  const compressedMf = path.join(dir, 'manifest.zz.json');
  const compressedManifest = fs.existsSync(compressedMf) ? readJsonArray(compressedMf) : [];
  const compressedByUrl = new Map();
  for (const item of compressedManifest) {
    if (item && item.url) compressedByUrl.set(item.url, item);
  }
  const resources = [];
  const byUrl = new Set();
  const excludes = appCfg && Array.isArray(appCfg.bundleExcludeUrls) ? appCfg.bundleExcludeUrls : [];
  let resourceBytes = 0;
  let compressedResourceBytes = 0;
  let compressibleBytes = 0;
  let gzipBytes = 0;
  let brBytes = 0;
  for (const item of manifest) {
    if (!item || !item.file) continue;
    const p = safeBundlePath(dir, item.file);
    const exists = p && fs.existsSync(p) && fs.statSync(p).isFile();
    const size = exists ? fs.statSync(p).size : Number(item.size || 0);
    const mime = item.mime || '';
    const compressible = exists && isCompressibleResource(mime, item.file);
    let gzipSize = 0;
    let brSize = 0;
    if (compressible && size <= 10 * 1024 * 1024) {
      const est = compressionEstimate(fs.readFileSync(p));
      gzipSize = est.gzip;
      brSize = est.br;
      compressibleBytes += size;
      gzipBytes += gzipSize;
      brBytes += brSize;
    }
    resourceBytes += size;
    const compressedItem = compressedByUrl.get(item.url || '');
    let storedFile = item.file;
    let storedSize = size;
    let encoding = '';
    if (compressedItem && compressedItem.file) {
      const sp = safeBundlePath(dir, compressedItem.file);
      storedFile = compressedItem.file;
      storedSize = sp && fs.existsSync(sp) && fs.statSync(sp).isFile()
        ? fs.statSync(sp).size
        : Number(compressedItem.size || size);
      encoding = compressedItem.encoding || '';
    }
    compressedResourceBytes += storedSize;
    byUrl.add(item.url || '');
    resources.push({
      url: item.url || '',
      file: item.file,
      storedFile,
      mime,
      size,
      sizeKB: Math.round(size / 102.4) / 10,
      storedSize,
      storedSizeKB: Math.round(storedSize / 102.4) / 10,
      encoding,
      hash: item.hash || '',
      costMs: item.costMs || 0,
      enabled: !(appCfg && matchesAny(item.url || '', excludes)),
      inManifest: true,
      configured: appCfg && Array.isArray(appCfg.bundleExtraUrls) ? matchesAny(item.url || '', appCfg.bundleExtraUrls) : false,
      compressible,
      gzipSize,
      gzipKB: gzipSize ? Math.round(gzipSize / 102.4) / 10 : 0,
      brSize,
      brKB: brSize ? Math.round(brSize / 102.4) / 10 : 0
    });
  }
  const configuredUrls = [
    ...(appCfg && Array.isArray(appCfg.bundleExtraUrls) ? appCfg.bundleExtraUrls : []),
    ...excludes
  ];
  for (const url of configuredUrls) {
    if (!url || byUrl.has(url)) continue;
    const file = fileNameForUrl(url);
    const p = safeBundlePath(dir, file);
    const exists = p && fs.existsSync(p) && fs.statSync(p).isFile();
    const size = exists ? fs.statSync(p).size : 0;
    const mime = mimeOfPath(file || url);
    resources.push({
      url,
      file,
      mime,
      size,
      sizeKB: Math.round(size / 102.4) / 10,
      storedSize: size,
      storedSizeKB: Math.round(size / 102.4) / 10,
      encoding: '',
      hash: '',
      costMs: 0,
      enabled: !matchesAny(url, excludes),
      inManifest: false,
      configured: true,
      compressible: exists && isCompressibleResource(mime, file),
      gzipSize: 0,
      gzipKB: 0,
      brSize: 0,
      brKB: 0
    });
  }
  const serverBytes = fs.readdirSync(dir)
    .reduce((s, f) => s + fs.statSync(path.join(dir, f)).size, 0);
  return {
    id,
    name: appCfg && appCfg.name ? appCfg.name : id,
    url: appCfg && appCfg.url ? appCfg.url : '',
    count: resources.length,
    sizeBytes: resourceBytes,
    sizeKB: Math.round(resourceBytes / 102.4) / 10,
    compressedSizeBytes: compressedResourceBytes,
    compressedSizeKB: Math.round(compressedResourceBytes / 102.4) / 10,
    serverSizeKB: Math.round(serverBytes / 102.4) / 10,
    bundleMaxSizeKB: appCfg && appCfg.bundleMaxSizeKB ? appCfg.bundleMaxSizeKB : 5120,
    configuredExtraCount: appCfg && Array.isArray(appCfg.bundleExtraUrls) ? appCfg.bundleExtraUrls.length : 0,
    builtAt: stat.mtime,
    manifestUrl: `/bundles/${id}/manifest.json`,
    config: {
      bundle: appCfg ? appCfg.bundle === true : false,
      swrDoc: appCfg ? appCfg.swrDoc !== false : false,
      prerender: appCfg ? appCfg.prerender !== false : false,
      bundleMaxSizeKB: appCfg && appCfg.bundleMaxSizeKB ? appCfg.bundleMaxSizeKB : 5120,
      bundleExtraUrls: appCfg && Array.isArray(appCfg.bundleExtraUrls) ? appCfg.bundleExtraUrls : [],
      bundleExcludeUrls: appCfg && Array.isArray(appCfg.bundleExcludeUrls) ? appCfg.bundleExcludeUrls : [],
      staticCache: appCfg && appCfg.staticCache ? appCfg.staticCache : null
    },
    compression: {
      compressibleKB: Math.round(compressibleBytes / 102.4) / 10,
      gzipKB: Math.round(gzipBytes / 102.4) / 10,
      brKB: Math.round(brBytes / 102.4) / 10,
      brSavingKB: Math.round(Math.max(0, compressibleBytes - brBytes) / 102.4) / 10,
      enabled: compressedManifest.length > 0,
      storedKB: Math.round(compressedResourceBytes / 102.4) / 10,
      rawKB: Math.round(resourceBytes / 102.4) / 10,
      savingKB: Math.round(Math.max(0, resourceBytes - compressedResourceBytes) / 102.4) / 10
    },
    resources
  };
}

// 已生成缓存清单的离线资源列表
app.get('/api/admin/bundles', (req, res) => {
  const out = [];
  const cfg = loadConfig();
  const seen = new Set();
  for (const appCfg of (cfg.apps || [])) {
    if (!appCfg || !appCfg.id) continue;
    seen.add(appCfg.id);
    const info = bundleInfo(appCfg.id, appCfg);
    out.push(info || {
      id: appCfg.id,
      name: appCfg.name || appCfg.id,
      url: appCfg.url || '',
      count: 0,
      sizeBytes: 0,
      sizeKB: 0,
      compressedSizeBytes: 0,
      compressedSizeKB: 0,
      serverSizeKB: 0,
      bundleMaxSizeKB: appCfg.bundleMaxSizeKB || 5120,
      configuredExtraCount: Array.isArray(appCfg.bundleExtraUrls) ? appCfg.bundleExtraUrls.length : 0,
      builtAt: null,
      manifestUrl: `/bundles/${appCfg.id}/manifest.json`,
      config: {
        bundle: appCfg.bundle === true,
        swrDoc: appCfg.swrDoc !== false,
        prerender: appCfg.prerender !== false,
        bundleMaxSizeKB: appCfg.bundleMaxSizeKB || 5120,
        bundleExtraUrls: Array.isArray(appCfg.bundleExtraUrls) ? appCfg.bundleExtraUrls : [],
        bundleExcludeUrls: Array.isArray(appCfg.bundleExcludeUrls) ? appCfg.bundleExcludeUrls : [],
        staticCache: appCfg.staticCache || null
      },
      compression: { compressibleKB: 0, gzipKB: 0, brKB: 0, brSavingKB: 0, enabled: false, storedKB: 0, rawKB: 0, savingKB: 0 },
      resources: []
    });
  }
  for (const id of fs.readdirSync(BUNDLES_DIR)) {
    if (seen.has(id) || id.startsWith('.')) continue;
    const appCfg = (cfg.apps || []).find((a) => a.id === id);
    const info = bundleInfo(id, appCfg);
    if (info) out.push(info);
  }
  res.json(out);
});

// 单个离线包资源开关:关闭=加入该站 bundleExcludeUrls,然后重生成 manifest;开启=从排除列表移除。
app.put('/api/admin/bundles/:id/resource', async (req, res) => {
  const c = loadConfig();
  const appCfg = (c.apps || []).find((a) => a.id === req.params.id);
  if (!appCfg) return res.status(404).json({ error: 'app not found' });
  const url = String(req.body && req.body.url || '').trim();
  const enabled = req.body && req.body.enabled === true;
  if (!/^https?:\/\//.test(url)) return res.status(400).json({ error: 'bad url' });
  const list = Array.isArray(appCfg.bundleExcludeUrls) ? appCfg.bundleExcludeUrls.slice() : [];
  const next = enabled ? list.filter((x) => x !== url) : (list.includes(url) ? list : list.concat(url));
  appCfg.bundleExcludeUrls = next;
  saveConfig(c);
  try {
    await runCacheBuilder('manifest', appCfg.id);
  } catch (e) {
    return res.status(500).json({ error: String(e && e.message || e) });
  }
  res.json({ ok: true, bundle: bundleInfo(appCfg.id, appCfg), bundleExcludeUrls: next });
});

// 手动导入指定静态资源:适合真机发现的跨域大图/JS/CSS。
// 成功导入的 URL 会加入 bundleExtraUrls,立即下载文件,并重生成 manifest + manifest.zz.json。
app.post('/api/admin/bundles/:id/import', async (req, res) => {
  const c = loadConfig();
  const appCfg = (c.apps || []).find((a) => a.id === req.params.id);
  if (!appCfg) return res.status(404).json({ error: 'app not found' });
  const imports = parseImportResources(req.body || {}, appCfg);
  if (!imports.length) return res.status(400).json({ error: '请填写至少一个 http(s) 静态资源 URL' });

  const dir = path.join(BUNDLES_DIR, appCfg.id);
  fs.mkdirSync(dir, { recursive: true });
  const maxResourceKB = Math.max(0, Number(req.body && req.body.maxResourceKB || 0));
  const maxResourceBytes = maxResourceKB > 0 ? maxResourceKB * 1024 : 0;
  const results = [];
  const importByUrl = new Map();
  for (const item of imports) importByUrl.set(item.url, item);
  for (const item of imports.slice(0, 200)) {
    try {
      results.push(await downloadImportResource(item, appCfg, dir, maxResourceBytes));
    } catch (e) {
      results.push({ ok: false, url: item.url, error: String(e && e.message || e) });
    }
  }

  const imported = results.filter((r) => r.ok);
  if (!imported.length) {
    return res.status(400).json({ ok: false, imported: 0, failed: results.length, results });
  }

  const importedUrls = imported.map((r) => r.url);
  const extra = new Set(Array.isArray(appCfg.bundleExtraUrls) ? appCfg.bundleExtraUrls : []);
  for (const url of importedUrls) extra.add(url);
  appCfg.bundleExtraUrls = Array.from(extra);
  if (Array.isArray(appCfg.bundleExcludeUrls)) {
    const importedSet = new Set(importedUrls);
    appCfg.bundleExcludeUrls = appCfg.bundleExcludeUrls.filter((url) => !importedSet.has(url));
  }
  const metrics = appCfg.bundleResourceMetrics && typeof appCfg.bundleResourceMetrics === 'object'
    ? Object.assign({}, appCfg.bundleResourceMetrics)
    : {};
  for (const item of imported) {
    const input = importByUrl.get(item.url) || {};
    metrics[item.url] = {
      size: item.size,
      measuredSize: input.size || item.size,
      mime: item.mime || '',
      costMs: input.costMs || item.costMs || 0,
      source: input.source || (input.costMs ? 'device' : 'server-import'),
      measuredAt: new Date().toISOString()
    };
  }
  appCfg.bundleResourceMetrics = metrics;
  if (req.body && req.body.enableBundle !== false) appCfg.bundle = true;
  saveConfig(c);

  let manifest = null;
  try {
    manifest = await runCacheBuilder('manifest', appCfg.id);
  } catch (e) {
    return res.status(500).json({
      ok: false,
      imported: imported.length,
      failed: results.length - imported.length,
      results,
      error: String(e && e.message || e)
    });
  }
  res.json({
    ok: true,
    imported: imported.length,
    failed: results.length - imported.length,
    results,
    manifest,
    bundle: bundleInfo(appCfg.id, appCfg),
    bundleExtraUrls: appCfg.bundleExtraUrls
  });
});

// 检查源站是否有新资源:访问目标站并对比当前 manifest,不写缓存文件。
app.post('/api/admin/bundles/:id/check', async (req, res) => {
  const c = loadConfig();
  const appCfg = c.apps.find((a) => a.id === req.params.id);
  if (!appCfg) return res.status(404).json({ error: 'app not found' });
  try {
    const r = await runCacheBuilder('check', appCfg.id);
    res.json(r);
  } catch (e) {
    res.status(500).json({ error: String(e && e.message || e) });
  }
});

// 增量更新服务器缓存:只下载新增/缺失资源,成功后原子替换 manifest。
app.post('/api/admin/bundles/:id/update', async (req, res) => {
  const c = loadConfig();
  const appCfg = c.apps.find((a) => a.id === req.params.id);
  if (!appCfg) return res.status(404).json({ error: 'app not found' });
  try {
    const r = await runCacheBuilder('update', appCfg.id);
    res.json(r);
  } catch (e) {
    res.status(500).json({ error: String(e && e.message || e) });
  }
});

// 为某个 app 构建服务器缓存文件:访问目标站、下载资源、清空旧缓存目录、生成 manifest。
app.post('/api/admin/bundles/:id/build', async (req, res) => {
  const c = loadConfig();
  const appCfg = c.apps.find((a) => a.id === req.params.id);
  if (!appCfg) return res.status(404).json({ error: 'app not found' });
  try {
    const r = await runCacheBuilder('build', appCfg.id);
    res.json(r);
  } catch (e) {
    res.status(500).json({ error: String(e && e.message || e) });
  }
});

// 仅生成缓存清单:扫描服务器已有缓存文件,不访问目标站,不清空目录。
app.post('/api/admin/bundles/:id/manifest', async (req, res) => {
  const c = loadConfig();
  const appCfg = c.apps.find((a) => a.id === req.params.id);
  if (!appCfg) return res.status(404).json({ error: 'app not found' });
  try {
    const r = await runCacheBuilder('manifest', appCfg.id);
    res.json(r);
  } catch (e) {
    res.status(500).json({ error: String(e && e.message || e) });
  }
});

// SPA 兜底:非 /api、非 /bundles 的 GET 一律回 index.html,交给前端路由(刷新子页面不 404)
if (fs.existsSync(WEB_DIST)) {
  app.get('*', (req, res, next) => {
    if (req.path.startsWith('/api') || req.path.startsWith('/bundles')) return next();
    res.sendFile(path.join(WEB_DIST, 'index.html'));
  });
}

async function buildWithRetry(appId, maxRetries = 3) {
  let lastErr = null;
  for (let i = 0; i < maxRetries; i++) {
    try {
      return await runCacheBuilder('build', appId);
    } catch (e) {
      lastErr = e;
      console.warn(`[AutoUpdate] ${appId} build 第 ${i + 1}/${maxRetries} 次失败: ${e.message}`);
      if (i < maxRetries - 1) await new Promise((r) => setTimeout(r, 5000 * (i + 1))); // 5s/10s 退避
    }
  }
  throw lastErr;
}

async function runAutoUpdateOnce(trigger = 'scheduled') {
  const cfg = loadConfig();
  if (trigger !== 'manual' && cfg.settings && cfg.settings.autoUpdate === false) {
    console.log(`[AutoUpdate] disabled, skip ${trigger}`);
    const log = { startedAt: new Date().toISOString(), finishedAt: new Date().toISOString(), trigger, skipped: true, reason: 'disabled', results: [] };
    try { fs.writeFileSync(AUTO_UPDATE_LOG, JSON.stringify(log, null, 2), 'utf8'); } catch {}
    return log;
  }
  if (autoUpdateRunning) {
    console.log('[AutoUpdate] 上一轮还在进行,跳过本轮');
    return;
  }
  autoUpdateRunning = true;
  const startedAt = new Date().toISOString();
  console.log(`[AutoUpdate] 开始自动检查更新 (${trigger}) ...`);
  const apps = (cfg.apps || []).filter((a) => a.bundle === true);
  const results = [];
  for (const app of apps) {
    const item = { id: app.id, name: app.name || app.id, action: 'none', ok: true, detail: '' };
    try {
      const chk = await runCacheBuilder('check', app.id);
      if (chk && chk.changed) {
        console.log(`[AutoUpdate] ${app.id} 有更新 → 增量更新`);
        try {
          const up = await runCacheBuilder('update', app.id);
          item.action = 'update';
          item.detail = `下载 ${up.downloaded || 0} 个新资源`;
        } catch (upErr) {
          console.warn(`[AutoUpdate] ${app.id} 增量更新失败,改为全量重建: ${upErr.message}`);
          const bd = await buildWithRetry(app.id);
          item.action = 'rebuild';
          item.detail = `重建 ${bd.count || 0} 个资源` + (bd.failed ? `(${bd.failed} 个失败)` : '');
        }
      } else {
        item.action = 'no-change';
        item.detail = '源站无更新';
      }
    } catch (e) {
      item.ok = false;
      item.detail = '检查/构建失败: ' + e.message;
      console.error(`[AutoUpdate] ${app.id} 失败: ${e.message}`);
    }
    results.push(item);
  }
  const log = { startedAt, finishedAt: new Date().toISOString(), trigger, results };
  try { fs.writeFileSync(AUTO_UPDATE_LOG, JSON.stringify(log, null, 2), 'utf8'); } catch {}
  autoUpdateRunning = false;
  console.log(`[AutoUpdate] 完成,处理 ${results.length} 个站`);
  return log;
}

function startAutoUpdateScheduler() {
  setTimeout(() => { runAutoUpdateOnce('startup').catch(() => {}); }, AUTO_UPDATE_FIRST_DELAY_MS);
  setInterval(() => { runAutoUpdateOnce('scheduled').catch(() => {}); }, AUTO_UPDATE_INTERVAL_MS);
  console.log(`[AutoUpdate] 定时器已启动:每 24 小时自动检查一次离线包更新`);
}

initDb(); // 后台连 MySQL 并建表(不阻塞;配置/离线包接口走文件,不依赖 DB)
app.listen(PORT, () => {
  console.log(`[youhua-admin] server on http://localhost:${PORT}`);
  console.log(`  鸿蒙 App 配置:  GET http://localhost:${PORT}/api/config`);
  console.log(`  离线包托管:      http://localhost:${PORT}/bundles/<id>/manifest.json`);
  console.log(`  后台登录:        账号 ${DEFAULT_USER} / 密码 ${DEFAULT_PASS}  (首登后可在后台改;或用 ADMIN_USER/ADMIN_PASS 环境变量)`);
  if (MASTER_TOKEN) console.log(`  主令牌已开启:    X-Admin-Token: <ADMIN_TOKEN>(脚本用)`);
  startAutoUpdateScheduler(); // 启动定时自动更新
});
