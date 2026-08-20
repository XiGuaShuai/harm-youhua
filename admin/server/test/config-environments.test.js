import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

function webConfig(url, title) {
  return JSON.stringify({ url, title });
}

async function waitForServer(baseUrl, child) {
  for (let attempt = 0; attempt < 80; attempt++) {
    if (child.exitCode !== null) throw new Error(`server exited early: ${child.exitCode}`);
    try {
      const response = await fetch(`${baseUrl}/api/config`);
      if (response.ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('server did not become ready');
}

async function requestJson(url, init = {}) {
  const response = await fetch(url, init);
  const text = await response.text();
  assert.equal(response.ok, true, `${response.status} ${url}: ${text}`);
  return JSON.parse(text);
}

test('isolates config overlays and offline bundles by environment', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'webaccel-env-'));
  const dataDir = path.join(root, 'data');
  const bundlesDir = path.join(root, 'bundles');
  const testBundleDir = path.join(bundlesDir, 'test', 'sample');
  const prodBundleDir = path.join(bundlesDir, 'prod', 'sample');
  fs.mkdirSync(dataDir, { recursive: true });
  fs.mkdirSync(testBundleDir, { recursive: true });
  fs.mkdirSync(prodBundleDir, { recursive: true });
  const testJson = webConfig('https://example.com/app', 'test');
  const preJson = webConfig('https://example.com/app', 'pre');
  const prodJson = webConfig('https://example.com/app', 'prod');
  const secretLoginBody = JSON.stringify({ username: 'tester', password: 'secret-value' });
  const secretConfigBody = JSON.stringify({ querySecret: 'config-secret-value' });
  const config = {
    version: 'fixture',
    apps: [{
      id: 'sample',
      name: 'Sample',
      url: 'https://example.com/app',
      scope: 'top',
      bundle: true,
      bundleEnvironments: ['test', 'prod'],
      configJson: testJson,
      configJsonFileName: 'legacy-test.json',
      configJsonSync: {
        enabled: true,
        loginUrl: 'https://test.example.com/login',
        loginBody: secretLoginBody,
        configUrl: 'https://test.example.com/config',
        configBody: secretConfigBody,
        tokenPath: 'token',
        tokenPrefix: 'Bearer ',
        configPath: 'data.configJson'
      },
      configJsonEnvironments: {
        pre: { configJson: preJson, configJsonFileName: 'pre.json' },
        prod: { configJson: prodJson, configJsonFileName: 'prod.json' }
      }
    }],
    blockHosts: [],
    settings: { configRefreshSec: 300 }
  };
  fs.writeFileSync(path.join(dataDir, 'config.json'), JSON.stringify(config, null, 2));
  const testManifest = JSON.stringify([{ url: 'https://example.com/test.js', file: 'test.js', mime: 'application/javascript' }]);
  const prodManifest = JSON.stringify([{ url: 'https://example.com/prod.js', file: 'prod.js', mime: 'application/javascript' }]);
  fs.writeFileSync(path.join(testBundleDir, 'manifest.json'), testManifest);
  fs.writeFileSync(path.join(testBundleDir, 'test.js'), 'console.log("test")');
  fs.writeFileSync(path.join(prodBundleDir, 'manifest.json'), prodManifest);
  fs.writeFileSync(path.join(prodBundleDir, 'prod.js'), 'console.log("prod")');

  const port = 19000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const serverDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const child = spawn(process.execPath, ['index.js'], {
    cwd: serverDir,
    env: {
      ...process.env,
      PORT: String(port),
      DATA_DIR: dataDir,
      BUNDLES_DIR: bundlesDir,
      ADMIN_USER: 'admin',
      ADMIN_PASS: 'admin123',
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

  const expected = { test: testJson, prod: prodJson };
  for (const environment of ['test', 'prod']) {
    const body = await requestJson(`${baseUrl}/${environment}/api/config`);
    assert.equal(body.environment, environment);
    assert.equal(body.apps.length, 1);
    assert.equal(body.apps[0].id, 'sample');
    assert.equal(body.apps[0].configJson, expected[environment]);
    assert.equal(body.apps[0].configEnvironment, environment);
    assert.equal(body.apps[0].bundle, true);
    assert.equal(body.apps[0].bundleConfigured, true);
    assert.equal(body.apps[0].manifestUrl, '/bundles/sample/manifest.json');
    assert.equal(Object.hasOwn(body.apps[0], 'configJsonEnvironments'), false);
    assert.equal(Object.hasOwn(body.apps[0], 'configJsonSync'), false);
  }
  const preBody = await requestJson(`${baseUrl}/pre/api/config`);
  assert.equal(preBody.environment, 'pre');
  assert.equal(preBody.apps.length, 0);
  const legacy = await requestJson(`${baseUrl}/api/config`);
  assert.equal(legacy.environment, 'prod');
  assert.equal(legacy.apps[0].configJson, prodJson);
  assert.equal(await (await fetch(`${baseUrl}/test/bundles/sample/manifest.json`)).text(), testManifest);
  assert.equal((await fetch(`${baseUrl}/pre/bundles/sample/manifest.json`)).status, 404);
  assert.equal(await (await fetch(`${baseUrl}/prod/bundles/sample/manifest.json`)).text(), prodManifest);
  assert.equal(await (await fetch(`${baseUrl}/bundles/sample/manifest.json`)).text(), prodManifest);

  const login = await requestJson(`${baseUrl}/api/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ username: 'admin', password: 'admin123' })
  });
  const adminHeaders = { 'content-type': 'application/json', 'x-admin-token': login.token };
  const adminConfig = await requestJson(`${baseUrl}/api/admin/config`, { headers: adminHeaders });
  assert.deepEqual(adminConfig.configEnvironments.map((item) => item.id), ['test', 'pre', 'prod']);
  assert.equal(adminConfig.apps[0].configJsonEnvironments.test.configJsonSync.loginBody, '******');
  assert.equal(adminConfig.apps[0].configJsonEnvironments.test.configJsonSync.configBody, '******');
  assert.equal(adminConfig.apps[0].configJsonEnvironments.test.configJsonSync.tokenPrefix, 'Bearer ');
  const fifaApp = {
    id: 'app_fifaworldcup',
    name: 'FIFA World Cup 2026',
    url: 'https://www.fifa.com/',
    scope: 'region',
    bundle: true,
    bundleEnvironments: ['test'],
    regions: ['2046772885148901377', '2037443812888760321'],
    regionNames: {
      '2046772885148901377': '??',
      '2037443812888760321': '??'
    }
  };
  await requestJson(`${baseUrl}/api/admin/apps`, {
    method: 'PUT',
    headers: adminHeaders,
    body: JSON.stringify({ apps: [adminConfig.apps[0], fifaApp] })
  });
  const fifaAdmin = await requestJson(`${baseUrl}/api/admin/config`, { headers: adminHeaders });
  const savedFifa = fifaAdmin.apps.find((item) => item.id === 'app_fifaworldcup');
  assert.ok(savedFifa.regions.includes('2039265040891826177'));
  assert.equal(savedFifa.regionNames['2037443812888760321'], '美国');
  assert.equal(savedFifa.regionNames['2046772885148901377'], '美国');
  const fifaGroup = (fifaAdmin.regions || []).filter((item) => String(item.name || '').startsWith('美国'));
  assert.equal(new Set(fifaGroup.map((item) => item.name)).size, fifaGroup.length);
  assert.ok(fifaGroup.some((item) => item.id === '2037443812888760321' && item.name === '美国 · 测试 · 2037443812888760321'));
  assert.ok(fifaGroup.some((item) => item.id === '2046772885148901377' && item.name === '美国 · 正式 · 2046772885148901377'));

  const testPublic = await requestJson(`${baseUrl}/test/api/config`);
  const testFifa = testPublic.apps.find((item) => item.id === 'app_fifaworldcup');
  assert.ok(testFifa);
  assert.deepEqual(testFifa.regions, ['2037443812888760321']);
  assert.equal(testFifa.regionName, '美国');
  assert.equal(testFifa.regionNames['2037443812888760321'], '美国');
  assert.equal(testPublic.regions.filter((item) => String(item.name || '').includes('美国')).length, 1);
  assert.equal(testPublic.regions.find((item) => item.id === '2037443812888760321').name, '美国');
  assert.equal((await requestJson(`${baseUrl}/prod/api/config`)).apps.some((item) => item.id === 'app_fifaworldcup'), false);
  assert.equal((await requestJson(`${baseUrl}/pre/api/config`)).apps.some((item) => item.id === 'app_fifaworldcup'), false);

  await requestJson(`${baseUrl}/api/admin/apps`, {
    method: 'PUT',
    headers: adminHeaders,
    body: JSON.stringify({ apps: adminConfig.apps })
  });
  let saved = JSON.parse(fs.readFileSync(path.join(dataDir, 'config.json'), 'utf8'));
  assert.equal(saved.apps[0].configJsonEnvironments.test.configJsonSync.loginBody, secretLoginBody);
  assert.equal(saved.apps[0].configJsonEnvironments.test.configJsonSync.configBody, secretConfigBody);

  const metadataOnly = {
    ...adminConfig.apps[0],
    name: 'Sample metadata updated',
    configJsonEnvironments: {
      test: { configJsonSync: adminConfig.apps[0].configJsonEnvironments.test.configJsonSync },
      pre: { configJsonSync: {} },
      prod: { configJsonSync: {} }
    }
  };
  await requestJson(`${baseUrl}/api/admin/apps/sample`, {
    method: 'PUT',
    headers: adminHeaders,
    body: JSON.stringify({ app: metadataOnly })
  });
  saved = JSON.parse(fs.readFileSync(path.join(dataDir, 'config.json'), 'utf8'));
  assert.equal(saved.apps[0].name, 'Sample metadata updated');
  assert.equal(saved.apps[0].configJsonEnvironments.test.configJson, testJson);
  assert.equal(saved.apps[0].configJsonEnvironments.pre.configJson, preJson);
  assert.equal(saved.apps[0].configJsonEnvironments.prod.configJson, prodJson);
  assert.equal(saved.apps[0].configJsonEnvironments.test.configJsonSync.loginBody, secretLoginBody);
  assert.equal(saved.apps[0].configJsonEnvironments.test.configJsonSync.configBody, secretConfigBody);

  const updatedPre = webConfig('https://example.com/app', 'pre-updated');
  await requestJson(`${baseUrl}/api/admin/bundles/sample/config-json`, {
    method: 'PUT',
    headers: adminHeaders,
    body: JSON.stringify({ environment: 'pre', configJson: updatedPre, fileName: 'pre-updated.json' })
  });
  saved = JSON.parse(fs.readFileSync(path.join(dataDir, 'config.json'), 'utf8'));
  assert.equal(saved.apps[0].configJsonEnvironments.test.configJson, testJson);
  assert.equal(saved.apps[0].configJsonEnvironments.pre.configJson, updatedPre);
  assert.equal(saved.apps[0].configJsonEnvironments.prod.configJson, prodJson);
  assert.equal(fs.readFileSync(path.join(testBundleDir, 'manifest.json'), 'utf8'), testManifest);
  assert.equal(fs.readFileSync(path.join(prodBundleDir, 'manifest.json'), 'utf8'), prodManifest);

  await requestJson(`${baseUrl}/api/admin/apps/sample`, {
    method: 'DELETE',
    headers: adminHeaders
  });
  saved = JSON.parse(fs.readFileSync(path.join(dataDir, 'config.json'), 'utf8'));
  assert.equal(saved.apps.length, 0);
});

test('pauses offline bundle delivery without removing the app or pack files', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'webaccel-pause-'));
  const dataDir = path.join(root, 'data');
  const bundlesDir = path.join(root, 'bundles');
  const testBundleDir = path.join(bundlesDir, 'test', 'sample');
  const prodBundleDir = path.join(bundlesDir, 'prod', 'sample');
  fs.mkdirSync(dataDir, { recursive: true });
  fs.mkdirSync(testBundleDir, { recursive: true });
  fs.mkdirSync(prodBundleDir, { recursive: true });
  const testJson = webConfig('https://example.com/app', 'test');
  const prodJson = webConfig('https://example.com/app', 'prod');
  fs.writeFileSync(path.join(dataDir, 'config.json'), JSON.stringify({
    version: 'fixture',
    apps: [{
      id: 'sample',
      name: 'Sample',
      url: 'https://example.com/app',
      scope: 'top',
      bundle: true,
      bundleEnvironments: ['test', 'prod'],
      configJsonEnvironments: {
        test: { configJson: testJson, configJsonFileName: 'test.json' },
        prod: { configJson: prodJson, configJsonFileName: 'prod.json' }
      }
    }],
    blockHosts: [],
    settings: { configRefreshSec: 300 }
  }, null, 2));
  const testManifest = JSON.stringify([{ url: 'https://example.com/test.js', file: 'test.js', mime: 'application/javascript' }]);
  const prodManifest = JSON.stringify([{ url: 'https://example.com/prod.js', file: 'prod.js', mime: 'application/javascript' }]);
  fs.writeFileSync(path.join(testBundleDir, 'manifest.json'), testManifest);
  fs.writeFileSync(path.join(testBundleDir, 'test.js'), 'console.log("test")');
  fs.writeFileSync(path.join(prodBundleDir, 'manifest.json'), prodManifest);
  fs.writeFileSync(path.join(prodBundleDir, 'prod.js'), 'console.log("prod")');

  const port = 19000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const child = spawn(process.execPath, ['index.js'], {
    cwd: path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'),
    env: {
      ...process.env,
      PORT: String(port),
      DATA_DIR: dataDir,
      BUNDLES_DIR: bundlesDir,
      ADMIN_USER: 'admin',
      ADMIN_PASS: 'admin123',
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

  const login = await requestJson(`${baseUrl}/api/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ username: 'admin', password: 'admin123' })
  });
  const adminHeaders = { 'content-type': 'application/json', 'x-admin-token': login.token };

  const paused = await requestJson(`${baseUrl}/api/admin/apps/sample/bundle-pause`, {
    method: 'PUT',
    headers: adminHeaders,
    body: JSON.stringify({ environment: 'test', paused: true })
  });
  assert.equal(paused.paused, true);
  assert.equal(paused.enabled, false);
  assert.deepEqual(paused.app.bundlePausedEnvironments, ['test']);

  const testPublic = await requestJson(`${baseUrl}/test/api/config`);
  const testApp = testPublic.apps.find((item) => item.id === 'sample');
  assert.ok(testApp);
  assert.equal(testApp.bundle, false);
  assert.equal(testApp.bundleConfigured, false);
  assert.equal(Object.hasOwn(testApp, 'bundlePausedEnvironments'), false);
  assert.equal(testApp.configJson, testJson);
  assert.equal(fs.existsSync(path.join(testBundleDir, 'manifest.json')), true);

  const prodPublic = await requestJson(`${baseUrl}/prod/api/config`);
  assert.equal(prodPublic.apps[0].bundle, true);
  assert.equal(prodPublic.apps[0].bundleConfigured, true);

  const metadataOnly = await requestJson(`${baseUrl}/api/admin/config`, { headers: adminHeaders });
  const metadataApp = { ...metadataOnly.apps[0], name: 'Sample still paused' };
  delete metadataApp.bundlePausedEnvironments;
  await requestJson(`${baseUrl}/api/admin/apps/sample`, {
    method: 'PUT',
    headers: adminHeaders,
    body: JSON.stringify({ app: metadataApp })
  });
  const saved = JSON.parse(fs.readFileSync(path.join(dataDir, 'config.json'), 'utf8'));
  assert.deepEqual(saved.apps[0].bundlePausedEnvironments, ['test']);

  const resumed = await requestJson(`${baseUrl}/api/admin/apps/sample/bundle-pause`, {
    method: 'PUT',
    headers: adminHeaders,
    body: JSON.stringify({ environment: 'test', paused: false })
  });
  assert.equal(resumed.paused, false);
  assert.equal(resumed.enabled, true);
  const testAfter = await requestJson(`${baseUrl}/test/api/config`);
  assert.equal(testAfter.apps[0].bundle, true);
  assert.equal(testAfter.apps[0].bundleConfigured, true);
});
