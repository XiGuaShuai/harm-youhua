const ENVIRONMENTS = ['test', 'pre', 'prod'];
const ENV_LABELS = { test: '测试', pre: '预发', prod: '正式' };
export const CONFIG_JSON_SYNC_STALE_MS = 3 * 60 * 1000;

function emptyEnv() {
  return { total: 0, ok: 0, fail: 0, skip: 0, changed: 0 };
}

export function summarizeConfigJsonSyncLog(log) {
  const results = Array.isArray(log && log.results) ? log.results : [];
  const byEnv = {
    test: emptyEnv(),
    pre: emptyEnv(),
    prod: emptyEnv()
  };
  const issues = [];
  for (const item of results) {
    const env = ENVIRONMENTS.includes(item && item.environment) ? item.environment : '';
    if (!env) continue;
    const row = byEnv[env];
    row.total += 1;
    const skipped = item.skipped === true;
    const failed = item.ok === false;
    if (failed || skipped) {
      if (skipped) row.skip += 1;
      else row.fail += 1;
      issues.push({
        environment: env,
        environmentName: ENV_LABELS[env],
        id: String(item.id || ''),
        name: String(item.name || item.id || ''),
        detail: String(item.detail || '').slice(0, 180)
      });
    } else {
      row.ok += 1;
    }
    if (item.changed) row.changed += 1;
  }
  return { byEnv, issues };
}

function envProblemText(byEnv) {
  const parts = [];
  for (const env of ENVIRONMENTS) {
    const row = byEnv[env];
    if (!row.fail && !row.skip) continue;
    const bits = [];
    if (row.fail) bits.push(`失败 ${row.fail}`);
    if (row.skip) bits.push(`卡住 ${row.skip}`);
    parts.push(`${ENV_LABELS[env]}${bits.join('、')}`);
  }
  return parts.join('；');
}

export function buildConfigJsonSyncStatus(input = {}) {
  const log = input.log || null;
  const now = typeof input.now === 'number' ? input.now : Date.now();
  const staleMs = typeof input.staleMs === 'number' ? input.staleMs : CONFIG_JSON_SYNC_STALE_MS;
  const summary = summarizeConfigJsonSyncLog(log);
  const finishedAt = String(log && log.finishedAt || '');
  const finishedMs = Date.parse(finishedAt);
  const running = input.running === true;
  const skippedRound = input.skippedRound && input.skippedRound.reason
    ? {
      at: String(input.skippedRound.at || ''),
      reason: String(input.skippedRound.reason || '')
    }
    : null;
  const skippedRecent = !!(skippedRound && skippedRound.at && (now - Date.parse(skippedRound.at) <= staleMs));
  const stale = !running && (!Number.isFinite(finishedMs) || (now - finishedMs) > staleMs);
  const failSkip = summary.issues.length > 0;
  const healthy = !stale && !skippedRecent && !failSkip;
  let message = 'configJson 三环境同步正常';
  if (skippedRecent) {
    message = `configJson 整轮同步被跳过：${skippedRound.reason}。正式环境可能继续使用旧 JSON`;
  } else if (failSkip) {
    message = `configJson 同步异常：${envProblemText(summary.byEnv)}`;
  } else if (stale) {
    message = 'configJson 超过 3 分钟没有完成新一轮同步，定时任务可能卡住';
  }
  return {
    healthy,
    stale,
    running,
    skippedRound: skippedRecent ? skippedRound : null,
    trigger: String(log && log.trigger || ''),
    startedAt: String(log && log.startedAt || ''),
    finishedAt,
    message,
    byEnv: summary.byEnv,
    issues: summary.issues.slice(0, 40)
  };
}

function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function renderConfigJsonSyncBannerJs() {
  return `(function () {
  function token() {
    try { return localStorage.getItem('admin_token') || ''; } catch (e) { return ''; }
  }
  function bar() {
    var el = document.getElementById('wa-sync-bar');
    if (el) return el;
    el = document.createElement('a');
    el.id = 'wa-sync-bar';
    el.href = '/config-json-sync.html';
    el.target = '_blank';
    el.rel = 'noopener';
    el.style.cssText = 'position:fixed;left:0;right:0;bottom:0;z-index:99999;padding:8px 16px;font:13px/1.4 sans-serif;text-decoration:none;display:none;box-shadow:0 -4px 16px rgba(31,36,51,.08)';
    document.body.appendChild(el);
    return el;
  }
  async function refresh() {
    var el = bar();
    var t = token();
    if (!t) { el.style.display = 'none'; return; }
    try {
      var res = await fetch('/api/admin/config-json-sync/status', {
        headers: { 'X-Admin-Token': t }
      });
      if (!res.ok) { el.style.display = 'none'; return; }
      var data = await res.json();
      el.style.display = 'block';
      if (data.healthy) {
        el.style.background = '#ecfdf3';
        el.style.color = '#067647';
        el.textContent = (data.message || 'configJson 三环境同步正常') + '  ·  点击查看详情';
      } else {
        el.style.background = '#fef3f2';
        el.style.color = '#b42318';
        el.textContent = (data.message || 'configJson 同步异常') + '  ·  系统会自动重拉，点击查看详情';
      }
    } catch (e) {
      el.style.display = 'none';
    }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', refresh);
  else refresh();
  setInterval(refresh, 20000);
})();`;
}

export function renderConfigJsonSyncLoginHtml() {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>configJson 同步状态</title>
  <style>
    body { font-family: sans-serif; background: #f4f6fb; color: #1f2433; margin: 0; padding: 48px 16px; }
    .card { max-width: 420px; margin: 0 auto; background: #fff; border-radius: 12px; padding: 24px; box-shadow: 0 8px 24px rgba(31,36,51,.08); }
    h1 { font-size: 20px; margin: 0 0 16px; }
    label { display: block; font-size: 13px; color: #5b6172; margin: 12px 0 6px; }
    input { width: 100%; box-sizing: border-box; padding: 10px 12px; border: 1px solid #d9dee8; border-radius: 8px; }
    button { margin-top: 18px; width: 100%; border: 0; background: #4f5bd5; color: #fff; padding: 10px 12px; border-radius: 8px; cursor: pointer; }
    .err { color: #b42318; font-size: 13px; min-height: 18px; margin-top: 10px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>查看 configJson 同步状态</h1>
    <form id="f">
      <label>账号</label>
      <input name="username" autocomplete="username" required>
      <label>密码</label>
      <input name="password" type="password" autocomplete="current-password" required>
      <div class="err" id="err"></div>
      <button type="submit">登录后查看</button>
    </form>
  </div>
  <script>
    document.getElementById('f').addEventListener('submit', async function (event) {
      event.preventDefault();
      const err = document.getElementById('err');
      err.textContent = '';
      const body = {
        username: event.target.username.value,
        password: event.target.password.value
      };
      try {
        const res = await fetch('/api/login', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          credentials: 'include',
          body: JSON.stringify(body)
        });
        const data = await res.json();
        if (!res.ok || !data.ok) {
          err.textContent = data.error || '登录失败';
          return;
        }
        location.reload();
      } catch (e) {
        err.textContent = e.message || '登录失败';
      }
    });
  </script>
</body>
</html>`;
}

export function renderConfigJsonSyncHtml(status = {}) {
  const healthy = status.healthy === true;
  const byEnv = status.byEnv || {};
  const issues = Array.isArray(status.issues) ? status.issues : [];
  const rows = ENVIRONMENTS.map((env) => {
    const row = byEnv[env] || emptyEnv();
    const bad = row.fail > 0 || row.skip > 0;
    return `<tr class="${bad ? 'bad' : ''}">
      <td>${ENV_LABELS[env]}</td>
      <td>${row.total}</td>
      <td>${row.ok}</td>
      <td>${row.fail}</td>
      <td>${row.skip}</td>
      <td>${row.changed}</td>
    </tr>`;
  }).join('');
  const issueRows = issues.length
    ? issues.map((item) => `<tr>
        <td>${escapeHtml(item.environmentName || item.environment)}</td>
        <td>${escapeHtml(item.name || item.id)}</td>
        <td>${escapeHtml(item.detail)}</td>
      </tr>`).join('')
    : '<tr><td colspan="3">没有失败或卡住的任务</td></tr>';
  const skipped = status.skippedRound
    ? `<p class="meta">整轮跳过：${escapeHtml(status.skippedRound.reason)}（${escapeHtml(status.skippedRound.at)}）</p>`
    : '';
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="20">
  <title>configJson 同步状态</title>
  <style>
    body { font-family: sans-serif; background: #f4f6fb; color: #1f2433; margin: 0; padding: 24px; }
    h1 { font-size: 22px; margin: 0 0 12px; }
    .banner { padding: 16px 18px; border-radius: 12px; font-size: 16px; font-weight: 700; margin-bottom: 18px; }
    .ok { background: #ecfdf3; color: #067647; }
    .bad { background: #fef3f2; color: #b42318; }
    .meta { color: #5b6172; font-size: 13px; margin: 6px 0; }
    table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 12px; overflow: hidden; margin: 16px 0; }
    th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #edf0f5; font-size: 14px; }
    th { background: #f8fafc; color: #5b6172; font-weight: 600; }
    tr.bad td { color: #b42318; font-weight: 600; }
    .hint { color: #8a90a2; font-size: 12px; }
  </style>
</head>
<body>
  <h1>configJson 同步状态</h1>
  <div class="banner ${healthy ? 'ok' : 'bad'}">${escapeHtml(status.message || '')}</div>
  <p class="meta">触发：${escapeHtml(status.trigger || '-')}　运行中：${status.running ? '是' : '否'}　过期：${status.stale ? '是' : '否'}</p>
  <p class="meta">开始：<span data-utc="${escapeHtml(status.startedAt)}"></span></p>
  <p class="meta">结束：<span data-utc="${escapeHtml(status.finishedAt)}"></span></p>
  ${skipped}
  <table>
    <thead><tr><th>环境</th><th>目标</th><th>成功</th><th>失败</th><th>卡住</th><th>有更新</th></tr></thead>
    <tbody>${rows}</tbody>
  </table>
  <table>
    <thead><tr><th>环境</th><th>应用</th><th>原因</th></tr></thead>
    <tbody>${issueRows}</tbody>
  </table>
  <p class="hint">页面每 20 秒刷新。同步失败或卡住会自动重新拉取，最多连续 3 轮。详细日志会定时删除。</p>
  <script>
    document.querySelectorAll('[data-utc]').forEach(function (el) {
      const raw = el.getAttribute('data-utc') || '';
      if (!raw) { el.textContent = '-'; return; }
      const date = new Date(raw);
      el.textContent = Number.isNaN(date.getTime()) ? raw : date.toLocaleString('zh-CN', { hour12: false, timeZone: 'Asia/Shanghai' }) + '（北京时间）';
    });
  </script>
</body>
</html>`;
}
