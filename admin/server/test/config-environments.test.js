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

test('serves environment config overlays while sharing one bundle', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'webaccel-env-'));
  const dataDir = path.join(root, 'data');
  const bundlesDir = path.join(root, 'bundles');
  const appBundleDir = path.join(bundlesDir, 'sample');
  fs.mkdirSync(dataDir, { recursive: true });
  fs.mkdirSync(appBundleDir, { recursive: true });
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
  const manifest = JSON.stringify([{ url: 'https://example.com/app.js', file: 'app.js', mime: 'application/javascript' }]);
  fs.writeFileSync(path.join(appBundleDir, 'manifest.json'), manifest);
  fs.writeFileSync(path.join(appBundleDir, 'app.js'), 'console.log("shared")');

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

  const expected = { test: testJson, pre: preJson, prod: prodJson };
  for (const environment of ['test', 'pre', 'prod']) {
    const body = await requestJson(`${baseUrl}/${environment}/api/config`);
    assert.equal(body.environment, environment);
    assert.equal(body.apps[0].configJson, expected[environment]);
    assert.equal(body.apps[0].configEnvironment, environment);
    assert.equal(body.apps[0].manifestUrl, '/bundles/sample/manifest.json');
    assert.equal(Object.hasOwn(body.apps[0], 'configJsonEnvironments'), false);
    assert.equal(Object.hasOwn(body.apps[0], 'configJsonSync'), false);
  }
  const legacy = await requestJson(`${baseUrl}/api/config`);
  assert.equal(legacy.environment, 'test');
  assert.equal(legacy.apps[0].configJson, testJson);
  assert.equal(await (await fetch(`${baseUrl}/pre/bundles/sample/manifest.json`)).text(), manifest);
  assert.equal(await (await fetch(`${baseUrl}/prod/bundles/sample/manifest.json`)).text(), manifest);

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

  await requestJson(`${baseUrl}/api/admin/apps`, {
    method: 'PUT',
    headers: adminHeaders,
    body: JSON.stringify({ apps: adminConfig.apps })
  });
  let saved = JSON.parse(fs.readFileSync(path.join(dataDir, 'config.json'), 'utf8'));
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
  assert.equal(fs.readFileSync(path.join(appBundleDir, 'manifest.json'), 'utf8'), manifest);
});
