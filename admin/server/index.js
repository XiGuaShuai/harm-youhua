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
      diskCapMB: 64,         // 运行时缓存上限
      docCheckSec: 60,       // 主文档版本校验节流(秒)
      bundleConcurrency: 8,  // 远程离线包后台下载并发(上限 8)
      prefetchChunks: true,  // 是否预取全站 chunk(Next.js 系有效)
      bytecodeCache: true,
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
    const hasBundle = fs.existsSync(mfPath);
    if (a.bundle && hasBundle) {
      // bundleVersion = 清单内容指纹:清单一变(资源增删改)它就变,设备据此判断"要不要更新离线包"
      let bundleVersion = '';
      try { bundleVersion = crypto.createHash('sha256').update(fs.readFileSync(mfPath)).digest('hex').slice(0, 16); } catch {}
      return Object.assign({}, a, { manifestUrl: `/bundles/${a.id}/manifest.json`, bundleVersion });
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
  const c = loadConfig(); c.apps = req.body.apps || []; res.json(saveConfig(c));
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

// 已生成缓存清单的离线资源列表
app.get('/api/admin/bundles', (req, res) => {
  const out = [];
  for (const id of fs.readdirSync(BUNDLES_DIR)) {
    const mf = path.join(BUNDLES_DIR, id, 'manifest.json');
    if (fs.existsSync(mf)) {
      const stat = fs.statSync(mf);
      let count = 0;
      try { count = JSON.parse(fs.readFileSync(mf, 'utf8')).length; } catch {}
      const size = fs.readdirSync(path.join(BUNDLES_DIR, id))
        .reduce((s, f) => s + fs.statSync(path.join(BUNDLES_DIR, id, f)).size, 0);
      out.push({ id, count, sizeKB: Math.round(size / 1024), builtAt: stat.mtime, manifestUrl: `/bundles/${id}/manifest.json` });
    }
  }
  res.json(out);
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
  if (autoUpdateRunning) {
    console.log('[AutoUpdate] 上一轮还在进行,跳过本轮');
    return;
  }
  autoUpdateRunning = true;
  const startedAt = new Date().toISOString();
  console.log(`[AutoUpdate] 开始自动检查更新 (${trigger}) ...`);
  const cfg = loadConfig();
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
