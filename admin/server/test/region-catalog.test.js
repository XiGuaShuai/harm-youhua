import test from 'node:test';
import assert from 'node:assert/strict';
import {
  displayRegionName,
  ensureFifaEnvironmentRegions,
  FIFA_US_REGION_IDS,
  resolveRegionName,
  selectRegionIdsForEnvironment
} from '../region-catalog.js';

test('distinguishes the same country across test/pre/prod IDs', () => {
  assert.equal(resolveRegionName('2037443812888760321', '??'), '美国');
  assert.equal(resolveRegionName('2039265040891826177', ''), '美国');
  assert.equal(resolveRegionName('2046772885148901377', '???(??)'), '美国');
  assert.equal(displayRegionName('2037443812888760321', '??'), '美国 · 测试 · 2037443812888760321');
  assert.equal(displayRegionName('2039265040891826177', ''), '美国 · 预发 · 2039265040891826177');
  assert.equal(displayRegionName('2046772885148901377', '??'), '美国 · 正式 · 2046772885148901377');
});

test('does not suffix shared short IDs', () => {
  assert.equal(displayRegionName('100016', '??'), '新加坡');
  assert.equal(displayRegionName('100014', '马来西亚'), '马来西亚');
});

test('ignores app titles and environment suffixes when resolving stored names', () => {
  assert.equal(
    resolveRegionName('2046772885148901377', 'FIFA World Cup 2026?', { appName: 'FIFA World Cup 2026' }),
    '美国'
  );
  assert.equal(resolveRegionName('2037443812888760321', '美国 · 测试'), '美国');
  assert.equal(resolveRegionName('2037443812888760321', '美国 · 测试 · 2037443812888760321'), '美国');
  assert.equal(resolveRegionName('2037443325779070977', '美国'), '加拿大');
});

test('uses a clean country name inside a single environment view', () => {
  assert.equal(displayRegionName('2037443812888760321', '??', { viewEnvironment: 'test' }), '美国');
  assert.equal(displayRegionName('2046772885148901377', '??', { viewEnvironment: 'prod' }), '美国');
  assert.deepEqual(
    selectRegionIdsForEnvironment(FIFA_US_REGION_IDS, 'test'),
    ['2037443812888760321']
  );
  assert.deepEqual(
    selectRegionIdsForEnvironment(FIFA_US_REGION_IDS, 'prod'),
    ['2046772885148901377']
  );
});

test('keeps FIFA US IDs for all three business environments', () => {
  const ids = ensureFifaEnvironmentRegions(['2046772885148901377', '2037443812888760321']);
  assert.deepEqual(new Set(ids), new Set(FIFA_US_REGION_IDS));
  assert.equal(ids.includes('2039265040891826177'), true);
});
