import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

async function waitForServer(baseUrl, child) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (child.exitCode !== null) throw new Error(`server exited early: ${child.exitCode}`);
    try {
      const response = await fetch(`${baseUrl}/api/config`);
      if (response.ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('server did not become ready');
}

async function request(url, init = {}) {
  const response = await fetch(url, init);
  const text = await response.text();
  let body = null;
  try { body = JSON.parse(text); } catch { body = text; }
  return { response, body, text };
}

function integrationHeaders(token, key = '') {
  const headers = {
    'content-type': 'application/json',
    'x-integration-token': token,
    'x-integration-client': 'node-test'
  };
  if (key) headers['x-idempotency-key'] = key;
  return headers;
}

function publicEnvironmentSnapshot(body) {
  return {
    environment: body.environment,
    apps: body.apps,
    regions: body.regions,
    blockHosts: body.blockHosts,
    settings: body.settings
  };
}

test('integration API is authenticated, idempotent, and hard-locked to test', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'webaccel-integration-'));
  const dataDir = path.join(root, 'data');
  const bundlesDir = path.join(root, 'bundles');
  fs.mkdirSync(dataDir, { recursive: true });
  for (const environment of ['test', 'pre', 'prod']) {
    fs.mkdirSync(path.join(bundlesDir, environment), { recursive: true });
  }

  const protectedConfig = {
    test: { configJson: JSON.stringify({ url: 'https://protected.example/app', title: 'test' }) },
    pre: { configJson: JSON.stringify({ url: 'https://protected.example/app', title: 'pre' }) },
    prod: { configJson: JSON.stringify({ url: 'https://protected.example/app', title: 'prod' }) }
  };
  fs.writeFileSync(path.join(dataDir, 'config.json'), JSON.stringify({
    version: 'fixture',
    apps: [{
      id: 'protected',
      name: 'Protected',
      url: 'https://protected.example/app',
      scope: 'top',
      bundle: true,
      bundleEnvironments: ['test', 'pre', 'prod'],
      configJsonEnvironments: protectedConfig
    }],
    blockHosts: [],
    settings: { configRefreshSec: 300 }
  }, null, 2));

  const protectedFiles = {};
  for (const environment of ['pre', 'prod']) {
    const dir = path.join(bundlesDir, environment, 'protected');
    fs.mkdirSync(dir, { recursive: true });
    const js = `console.log(${JSON.stringify(environment)})`;
    const manifest = JSON.stringify([{
      url: `https://protected.example/${environment}.js`,
      file: `${environment}.js`,
      mime: 'application/javascript'
    }]);
    fs.writeFileSync(path.join(dir, `${environment}.js`), js);
    fs.writeFileSync(path.join(dir, 'manifest.json'), manifest);
    protectedFiles[environment] = {
      manifest: crypto.createHash('sha256').update(manifest).digest('hex'),
      js: crypto.createHash('sha256').update(js).digest('hex')
    };
  }

  const port = 22000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const serverDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const token = 'integration-test-token';
  const child = spawn(process.execPath, ['index.js'], {
    cwd: serverDir,
    env: {
      ...process.env,
      PORT: String(port),
      DATA_DIR: dataDir,
      BUNDLES_DIR: bundlesDir,
      ADMIN_USER: 'test-admin',
      ADMIN_PASS: 'test-only-password',
      INTEGRATION_API_TOKEN: token,
      DISABLE_SCHEDULERS: '1',
      DB_HOST: '127.0.0.1',
      DB_PORT: '1'
    },
    stdio: 'ignore',
    windowsHide: true
  });
  t.after(() => {
    child.kill();
    fs.rmSync(root, { recursive: true, force: true });
  });
  await waitForServer(baseUrl, child);

  const preBefore = publicEnvironmentSnapshot((await request(`${baseUrl}/pre/api/config`)).body);
  const prodBefore = publicEnvironmentSnapshot((await request(`${baseUrl}/prod/api/config`)).body);
  const normalizedBefore = JSON.parse(fs.readFileSync(path.join(dataDir, 'config.json'), 'utf8'));
  const protectedBefore = normalizedBefore.apps.find((item) => item.id === 'protected');
  const protectedPreBefore = structuredClone(protectedBefore.configJsonEnvironments.pre);
  const protectedProdBefore = structuredClone(protectedBefore.configJsonEnvironments.prod);

  let result = await request(`${baseUrl}/api/integration/v1/apps/external_demo?environment=test`);
  assert.equal(result.response.status, 401);

  result = await request(`${baseUrl}/api/integration/v1/apps/external_demo`, {
    headers: integrationHeaders(token)
  });
  assert.equal(result.response.status, 400);
  assert.equal(result.body.code, 'environment_required');

  result = await request(`${baseUrl}/api/integration/v1/apps/external_demo`, {
    method: 'PUT',
    headers: integrationHeaders(token, 'create-prod-001'),
    body: JSON.stringify({ environment: 'prod', app: { name: 'Forbidden', url: 'https://example.test/app' } })
  });
  assert.equal(result.response.status, 403);
  assert.equal(result.body.code, 'test_environment_only');

  result = await request(`${baseUrl}/api/integration/v1/apps/invalid_url`, {
    method: 'PUT',
    headers: integrationHeaders(token, 'invalid-url-001'),
    body: JSON.stringify({
      environment: 'test',
      app: { name: 'Invalid URL', url: 'file:///tmp/not-allowed', scope: 'top' }
    })
  });
  assert.equal(result.response.status, 400);
  assert.equal(result.body.code, 'invalid_app');

  result = await request(`${baseUrl}/api/integration/v1/apps/protected`, {
    method: 'PUT',
    headers: integrationHeaders(token, 'protect-app-001'),
    body: JSON.stringify({
      environment: 'test',
      app: { name: 'Must not change', url: 'https://protected.example/app' }
    })
  });
  assert.equal(result.response.status, 409);
  assert.equal(result.body.code, 'protected_environment_state');

  result = await request(`${baseUrl}/api/integration/v1/apps/external_demo`, {
    method: 'PUT',
    headers: integrationHeaders(token, 'create-app-001'),
    body: JSON.stringify({
      environment: 'test',
      app: {
        name: 'External Demo',
        url: 'https://example.test/app',
        scope: 'region',
        regions: [{ id: 'test-region-1', name: '测试地区一' }],
        routes: ['/app', '/detail'],
        bundle: true
      }
    })
  });
  assert.equal(result.response.status, 201, result.text);
  assert.equal(result.body.environment, 'test');
  assert.deepEqual(result.body.app.bundleEnvironments, ['test']);
  assert.deepEqual(result.body.app.regions, ['test-region-1']);

  result = await request(`${baseUrl}/api/integration/v1/apps/external_demo/regions`, {
    method: 'PUT',
    headers: integrationHeaders(token, 'regions-001'),
    body: JSON.stringify({
      environment: 'test',
      regions: [
        { id: 'test-region-1', name: '测试地区一' },
        { id: 'test-region-2', name: '测试地区二' }
      ]
    })
  });
  assert.equal(result.response.status, 200, result.text);
  assert.deepEqual(result.body.app.regions, ['test-region-1', 'test-region-2']);

  const configJson = { url: 'https://example.test/app', title: 'test config only', version: 1 };
  result = await request(`${baseUrl}/api/integration/v1/apps/external_demo/config-json`, {
    method: 'PUT',
    headers: integrationHeaders(token, 'config-json-001'),
    body: JSON.stringify({ environment: 'test', configJson, fileName: 'external-demo-test.json' })
  });
  assert.equal(result.response.status, 200, result.text);
  assert.equal(result.body.configJson.environment, 'test');

  const source = `const testOnly = ${JSON.stringify('x'.repeat(4096))};\nconsole.log(testOnly.length);`;
  const encoded = Buffer.from(source).toString('base64');
  const resourceBody = {
    environment: 'test',
    resources: [{
      url: 'https://example.test/assets/app.12345678.js',
      mime: 'application/javascript',
      contentBase64: encoded,
      sha256: crypto.createHash('sha256').update(source).digest('hex')
    }]
  };
  result = await request(`${baseUrl}/api/integration/v1/apps/external_demo/resources/upload`, {
    method: 'POST',
    headers: integrationHeaders(token, 'resource-upload-001'),
    body: JSON.stringify(resourceBody)
  });
  assert.equal(result.response.status, 200, result.text);
  assert.equal(result.body.imported, 1);
  assert.equal(result.body.bundle.count, 1);

  const replay = await request(`${baseUrl}/api/integration/v1/apps/external_demo/resources/upload`, {
    method: 'POST',
    headers: integrationHeaders(token, 'resource-upload-001'),
    body: JSON.stringify(resourceBody)
  });
  assert.equal(replay.response.status, 200, replay.text);
  assert.equal(replay.response.headers.get('x-idempotent-replay'), 'true');
  assert.deepEqual(replay.body, result.body);

  const conflict = await request(`${baseUrl}/api/integration/v1/apps/external_demo/resources/upload`, {
    method: 'POST',
    headers: integrationHeaders(token, 'resource-upload-001'),
    body: JSON.stringify({ ...resourceBody, maxResourceKB: 1024 })
  });
  assert.equal(conflict.response.status, 409);
  assert.equal(conflict.body.code, 'idempotency_conflict');

  const login = await request(`${baseUrl}/api/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ username: 'test-admin', password: 'test-only-password' })
  });
  assert.equal(login.response.status, 200, login.text);
  const paused = await request(`${baseUrl}/api/admin/apps/external_demo/bundle-pause`, {
    method: 'PUT',
    headers: { 'content-type': 'application/json', 'x-admin-token': login.body.token },
    body: JSON.stringify({ environment: 'test', paused: true })
  });
  assert.equal(paused.response.status, 200, paused.text);
  assert.equal(paused.body.paused, true);

  const updateWhilePaused = await request(`${baseUrl}/api/integration/v1/apps/external_demo/resources/upload`, {
    method: 'POST',
    headers: integrationHeaders(token, 'resource-update-paused-001'),
    body: JSON.stringify(resourceBody)
  });
  assert.equal(updateWhilePaused.response.status, 200, updateWhilePaused.text);
  assert.equal(updateWhilePaused.body.bundle.config.bundlePaused, true);
  assert.equal(updateWhilePaused.body.bundle.config.bundle, false);

  const pausedPublic = (await request(`${baseUrl}/test/api/config`)).body;
  assert.equal(pausedPublic.apps.find((item) => item.id === 'external_demo').bundle, false);

  const resumed = await request(`${baseUrl}/api/admin/apps/external_demo/bundle-pause`, {
    method: 'PUT',
    headers: { 'content-type': 'application/json', 'x-admin-token': login.body.token },
    body: JSON.stringify({ environment: 'test', paused: false })
  });
  assert.equal(resumed.response.status, 200, resumed.text);
  assert.equal(resumed.body.enabled, true);

  const status = await request(`${baseUrl}/api/integration/v1/apps/external_demo?environment=test`, {
    headers: integrationHeaders(token)
  });
  assert.equal(status.response.status, 200, status.text);
  assert.equal(JSON.parse(status.body.app.configJson).title, 'test config only');
  assert.equal(status.body.app.offlineBundle.count, 1);

  const testPublic = (await request(`${baseUrl}/test/api/config`)).body;
  const testApp = testPublic.apps.find((item) => item.id === 'external_demo');
  assert.ok(testApp);
  assert.equal(testApp.bundle, true);
  assert.equal(testApp.configEnvironment, 'test');
  assert.equal(JSON.parse(testApp.configJson).title, 'test config only');
  assert.deepEqual(testApp.regions, ['test-region-1', 'test-region-2']);

  const manifestResponse = await fetch(`${baseUrl}/test/bundles/external_demo/manifest.json`);
  assert.equal(manifestResponse.status, 200);
  const manifest = await manifestResponse.json();
  assert.equal(manifest.length, 1);
  assert.equal(manifest[0].url, 'https://example.test/assets/app.12345678.js');
  assert.equal(fs.existsSync(path.join(bundlesDir, 'test', 'external_demo', 'manifest.zz.json')), true);

  const preAfter = publicEnvironmentSnapshot((await request(`${baseUrl}/pre/api/config`)).body);
  const prodAfter = publicEnvironmentSnapshot((await request(`${baseUrl}/prod/api/config`)).body);
  assert.deepEqual(preAfter, preBefore);
  assert.deepEqual(prodAfter, prodBefore);
  for (const environment of ['pre', 'prod']) {
    const dir = path.join(bundlesDir, environment, 'protected');
    assert.equal(
      crypto.createHash('sha256').update(fs.readFileSync(path.join(dir, 'manifest.json'))).digest('hex'),
      protectedFiles[environment].manifest
    );
    assert.equal(
      crypto.createHash('sha256').update(fs.readFileSync(path.join(dir, `${environment}.js`))).digest('hex'),
      protectedFiles[environment].js
    );
    assert.equal(fs.existsSync(path.join(bundlesDir, environment, 'external_demo')), false);
  }

  const saved = JSON.parse(fs.readFileSync(path.join(dataDir, 'config.json'), 'utf8'));
  const protectedApp = saved.apps.find((item) => item.id === 'protected');
  assert.deepEqual(protectedApp.configJsonEnvironments.pre, protectedPreBefore);
  assert.deepEqual(protectedApp.configJsonEnvironments.prod, protectedProdBefore);
  const externalApp = saved.apps.find((item) => item.id === 'external_demo');
  assert.deepEqual(externalApp.bundleEnvironments, ['test']);
  assert.equal(externalApp.configJsonEnvironments.pre.configJson, '');
  assert.equal(externalApp.configJsonEnvironments.prod.configJson, '');

  const auditLines = fs.readFileSync(path.join(dataDir, 'integration-audit.jsonl'), 'utf8').trim().split(/\r?\n/);
  assert.ok(auditLines.length >= 7);
  const auditRecords = auditLines.map((line) => JSON.parse(line));
  assert.ok(auditRecords.map((record) => record.action).includes('app.resources.upload'));
  assert.ok(auditRecords.some((record) => record.appId === 'external_demo' && record.environment === 'test'));
});
