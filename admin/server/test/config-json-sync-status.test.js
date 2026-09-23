import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildConfigJsonSyncStatus,
  renderConfigJsonSyncBannerJs,
  renderConfigJsonSyncHtml,
  summarizeConfigJsonSyncLog
} from '../config-json-sync-status.js';

test('summarizes failed and stuck prod tasks', () => {
  const summary = summarizeConfigJsonSyncLog({
    results: [
      { id: 'a', environment: 'test', ok: true },
      { id: 'hanchao_subway', name: '韩巢韩国地铁', environment: 'prod', ok: false, skipped: true, detail: '上一次任务仍在执行' },
      { id: 'xe', environment: 'prod', ok: false, detail: 'fetch failed' }
    ]
  });
  assert.equal(summary.byEnv.test.ok, 1);
  assert.equal(summary.byEnv.prod.skip, 1);
  assert.equal(summary.byEnv.prod.fail, 1);
  assert.equal(summary.issues.length, 2);
});

test('marks skipped round as unhealthy', () => {
  const now = Date.parse('2026-09-07T06:50:00.000Z');
  const status = buildConfigJsonSyncStatus({
    log: { finishedAt: '2026-09-07T06:49:00.000Z', results: [] },
    now,
    skippedRound: { at: '2026-09-07T06:49:30.000Z', reason: 'previous sync still running' }
  });
  assert.equal(status.healthy, false);
  assert.match(status.message, /跳过/);
});

test('html banner shows the current alert', () => {
  const html = renderConfigJsonSyncHtml({
    healthy: false,
    message: 'configJson 同步异常：正式卡住 24',
    byEnv: {
      test: { total: 34, ok: 34, fail: 0, skip: 0, changed: 0 },
      pre: { total: 26, ok: 26, fail: 0, skip: 0, changed: 0 },
      prod: { total: 26, ok: 2, fail: 0, skip: 24, changed: 0 }
    },
    issues: [{ environmentName: '正式', name: '韩巢韩国地铁', detail: '上一次任务仍在执行' }]
  });
  assert.match(html, /正式卡住 24/);
  assert.match(html, /韩巢韩国地铁/);
  assert.match(html, /http-equiv="refresh"/);
});

test('admin banner script polls sync status', () => {
  const js = renderConfigJsonSyncBannerJs();
  assert.match(js, /config-json-sync\/status/);
  assert.match(js, /admin_token/);
});
