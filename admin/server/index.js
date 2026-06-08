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

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_FILE = path.join(__dirname, 'data', 'config.json');
const USERS_FILE = path.join(__dirname, 'data', 'users.json');
const SESSIONS_FILE = path.join(__dirname, 'data', 'sessions.json');
const BUNDLES_DIR = path.join(__dirname, 'bundles');
const CACHE_BUILDER = path.join(__dirname, 'cache-builder.js');
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
        prerender: true,     // 离屏预渲染
        codeCache: false,    // 元服务不支持字节码注入
        bundle: false        // 非 Next.js(Adobe AEM+React),靠运行时通用层缓存,不做 Next 打包
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
      diskCapMB: 64,        // 运行时缓存上限
      docCheckSec: 60,      // 主文档版本校验节流(秒)
      bundleConcurrency: 3, // 远程离线包后台下载并发
      bytecodeCache: true
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

// ——————————————— Express ———————————————
const app = express();
app.use(cors());
app.use(express.json({ limit: '4mb' }));

// 鸿蒙 App 开机拉取(公开)
// 对启用离线包且服务端已有缓存清单的 app,附上 manifestUrl —— App 据此去服务器下载缓存资源
app.get('/api/config', (req, res) => {
  const c = loadConfig();
  const apps = (c.apps || []).map((a) => {
    const hasBundle = fs.existsSync(path.join(BUNDLES_DIR, a.id, 'manifest.json'));
    if (a.bundle && hasBundle) {
      return Object.assign({}, a, { manifestUrl: `/bundles/${a.id}/manifest.json` });
    }
    return a;
  });
  res.json(Object.assign({}, c, { apps }));
});

// 离线包静态托管:App 从 /bundles/<id>/manifest.json 拉取
app.use('/bundles', express.static(BUNDLES_DIR));

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

app.listen(PORT, () => {
  console.log(`[youhua-admin] server on http://localhost:${PORT}`);
  console.log(`  鸿蒙 App 配置:  GET http://localhost:${PORT}/api/config`);
  console.log(`  离线包托管:      http://localhost:${PORT}/bundles/<id>/manifest.json`);
  console.log(`  后台登录:        账号 ${DEFAULT_USER} / 密码 ${DEFAULT_PASS}  (首登后可在后台改;或用 ADMIN_USER/ADMIN_PASS 环境变量)`);
  if (MASTER_TOKEN) console.log(`  主令牌已开启:    X-Admin-Token: <ADMIN_TOKEN>(脚本用)`);
});
