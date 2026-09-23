const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
// Exercise the production route and bundleInfo functions with isolated filesystem/config fixtures.
const source = fs.readFileSync(process.argv[2] || path.join(__dirname, '..', 'index.js'), 'utf8');
const infoStart = source.indexOf('function bundleInfo(');
const routeStart = source.indexOf("app.get('/api/admin/bundles',");
const routeEnd = source.indexOf("app.put('/api/admin/bundles/:id/config-json'", routeStart);
assert(infoStart >= 0 && routeStart > infoStart && routeEnd > routeStart);
const definitionEnd = source.lastIndexOf('//', routeStart);
const fixtures = [
  {id: 'shared', bundle: true, bundleEnvironments: ['test', 'pre'], json: {test: 'TEST', pre: 'PRE'}},
  {id: 'prod-only', bundle: true, bundleEnvironments: ['prod'], json: {test: 'WRONG', prod: 'PROD'}},
  {id: 'paused', bundle: true, bundleEnvironments: ['prod'], paused: ['prod'], json: {prod: 'PROD'}},
  {id: 'disabled', bundle: false, bundleEnvironments: ['prod'], json: {}},
  {id: 'unbuilt', bundle: true, bundleEnvironments: ['prod'], json: {test: 'MUST NOT LEAK'}},
  {id: 'test-only', bundle: true, bundleEnvironments: ['test'], json: {test: 'TEST'}}
];
let handler;
const context = {
  path: path.posix, DEFAULT_CONFIG_ENVIRONMENT: 'test',
  normalizeConfigEnvironment: (env, fallback) => ['test', 'pre', 'prod'].includes(env) ? env : fallback,
  app: {get(url, fn) { assert.equal(url, '/api/admin/bundles'); handler = fn; }},
  loadConfig: () => ({apps: fixtures}),
  requestBundleEnvironment: req => req.environment,
  bundleRoot: env => '/bundles/' + env,
  normalizeBundleEnvironments: app => app.bundleEnvironments || ['prod'],
  normalizeBundlePausedEnvironments: app => app.paused || [],
  bundlePausedInEnvironment: (app, env) => (app.paused || []).includes(env),
  bundleEnabledInEnvironment: (app, env) => app.bundle && app.bundleEnvironments.includes(env) && !(app.paused || []).includes(env),
  configJsonInfo(app, env = 'test') {
    const json = app.json?.[env] || '';
    return {hasConfigJson: !!json, configJsonBytes: json.length, configJsonSizeKB: json.length / 1024,
            configJsonFileName: json ? env + '.json' : ''};
  },
  configJsonEnvironmentInfo: () => ({}),
  readJsonArray: () => [],
  fs: {
    existsSync(file) { return !file.includes('/unbuilt/') && !file.includes('/test-only/') && file.endsWith('/manifest.json'); },
    statSync: () => ({size: 0, mtime: new Date('2026-09-22T00:00:00Z')}),
    readdirSync(dir) {
      // A known app's old files must not reintroduce it; genuinely unregistered artifacts stay visible.
      return /^\/bundles\/[^/]+$/.test(dir) ? ['shared', 'orphan'] : [];
    }
  }
};
vm.createContext(context);
vm.runInContext(source.slice(infoStart, definitionEnd) + '\n' + source.slice(routeStart, routeEnd), context);
function list(environment) { let rows; handler({environment}, {json(value) { rows = value; }}); return rows; }
const prod = list('prod');
assert.deepEqual(Array.from(prod, a => a.id).sort(), ['disabled', 'orphan', 'paused', 'prod-only', 'unbuilt']);
assert.equal(prod.find(a => a.id === 'prod-only').configJsonFileName, 'prod.json');
assert.equal(prod.find(a => a.id === 'unbuilt').hasConfigJson, false);
assert.equal(prod.find(a => a.id === 'unbuilt').config.hasConfigJson, false);
assert.equal(prod.find(a => a.id === 'paused').config.bundle, false);
assert.equal(prod.find(a => a.id === 'disabled').config.bundle, false);
const test = list('test');
assert(test.some(a => a.id === 'shared'));
assert(test.some(a => a.id === 'test-only'));
assert(!test.some(a => a.id === 'prod-only'));
assert.equal(test.find(a => a.id === 'shared').configJsonFileName, 'test.json');
const pre = list('pre');
assert.equal(pre.find(a => a.id === 'shared').configJsonFileName, 'pre.json');
console.log('PASS: environment filtering, paused/disabled entries, built/unbuilt configJson metadata, and orphan handling.');
