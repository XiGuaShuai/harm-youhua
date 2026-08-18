<script setup>
import { ref, onMounted, computed } from 'vue';
import { storeToRefs } from 'pinia';
import { useRouter } from 'vue-router';
import { ElMessage, ElMessageBox } from 'element-plus';
import { Box, EditPen, MoreFilled, Plus, Refresh, Search, Upload } from '@element-plus/icons-vue';
import api from '../api';
import { useConfigStore } from '../stores/config';

const store = useConfigStore();
const router = useRouter();
const { apps } = storeToRefs(store);

const dialog = ref(false);
const editing = ref(null);
const activeGroup = ref('top');
const activeDialogTab = ref('base');
const appQuery = ref('');
const groupQuery = ref('');
const CONFIG_ENVIRONMENT_OPTIONS = [
  { id: 'test', name: '测试' },
  { id: 'pre', name: '预发' },
  { id: 'prod', name: '正式' }
];
// 旧配置中的部分地区名称曾以 "??" 保存。显示层统一用已知地区名或可读的 ID 兜底，不能把问号直接展示给运营人员。
const REGION_NAME_FALLBACKS = {
  '100003': '泰国',
  '100004': '中国香港',
  '100006': '韩国',
  '100009': '中国澳门',
  '100014': '马来西亚',
  '100016': '新加坡',
  '100017': '日本',
  '100106': '越南',
  '100253': '阿联酋',
  '100296': '西班牙',
  '100452': '俄罗斯',
  '2007696801692241922': '菲律宾',
  '1988526837953462273': '印度尼西亚',
  '2037443812888760321': '美国',
  '2046772885148901377': '美国'
};
const activeConfigEnvironment = ref('test');
const activeConfigEnvironmentName = computed(() =>
  CONFIG_ENVIRONMENT_OPTIONS.find((item) => item.id === activeConfigEnvironment.value)?.name || activeConfigEnvironment.value
);
const form = ref(emptyForm());
const detecting = ref(false);

const bundleMap = ref({});

function emptyConfigEnvironment() {
  return {
    configJson: '',
    configJsonFileName: '',
    configJsonSyncedAt: '',
    configJsonSync: {
      enabled: false,
      loginUrl: '',
      loginMethod: 'POST',
      loginHeaders: {},
      loginBody: '',
      configUrl: '',
      configMethod: 'GET',
      configHeaders: {},
      configBody: '',
      tokenPath: '',
      tokenHeader: 'Authorization',
      tokenPrefix: 'Bearer ',
      configPath: ''
    }
  };
}

function configEnvironmentsOf(row) {
  const source = row?.configJsonEnvironments || {};
  const legacyTest = {
    configJson: row?.configJson || '',
    configJsonFileName: row?.configJsonFileName || '',
    configJsonSyncedAt: row?.configJsonSyncedAt || '',
    configJsonSync: row?.configJsonSync || {}
  };
  const result = {};
  CONFIG_ENVIRONMENT_OPTIONS.forEach(({ id }) => {
    const value = source[id] || (id === 'test' ? legacyTest : {});
    result[id] = {
      ...emptyConfigEnvironment(),
      ...value,
      configJsonSync: { ...emptyConfigEnvironment().configJsonSync, ...(value.configJsonSync || {}) }
    };
  });
  return result;
}

function applyConfigEnvironment(environment) {
  const value = form.value.configJsonEnvironments?.[environment] || emptyConfigEnvironment();
  const sync = value.configJsonSync || {};
  form.value.configJson = value.configJson || '';
  form.value.configJsonFileName = value.configJsonFileName || '';
  form.value.configJsonSyncEnabled = sync.enabled === true;
  form.value.configJsonSyncLoginUrl = sync.loginUrl || '';
  form.value.configJsonSyncLoginMethod = sync.loginMethod || 'POST';
  form.value.configJsonSyncLoginHeadersText = stringifyObject(sync.loginHeaders);
  form.value.configJsonSyncLoginBody = sync.loginBody || '';
  form.value.configJsonSyncConfigUrl = sync.configUrl || '';
  form.value.configJsonSyncConfigMethod = sync.configMethod || 'GET';
  form.value.configJsonSyncConfigHeadersText = stringifyObject(sync.configHeaders);
  form.value.configJsonSyncConfigBody = sync.configBody || '';
  form.value.configJsonSyncTokenPath = sync.tokenPath || '';
  form.value.configJsonSyncTokenHeader = sync.tokenHeader || 'Authorization';
  form.value.configJsonSyncTokenPrefix = sync.tokenPrefix ?? 'Bearer ';
  form.value.configJsonSyncConfigPath = sync.configPath || '';
}

function captureConfigEnvironment(environment = activeConfigEnvironment.value) {
  if (!form.value.configJsonEnvironments) form.value.configJsonEnvironments = configEnvironmentsOf({});
  form.value.configJsonEnvironments[environment] = {
    configJson: (form.value.configJson || '').trim(),
    configJsonFileName: (form.value.configJsonFileName || '').trim(),
    configJsonSyncedAt: form.value.configJsonEnvironments[environment]?.configJsonSyncedAt || '',
    configJsonSync: {
      enabled: form.value.configJsonSyncEnabled,
      loginUrl: (form.value.configJsonSyncLoginUrl || '').trim(),
      loginMethod: form.value.configJsonSyncLoginMethod || 'POST',
      loginHeaders: parseObjectText(form.value.configJsonSyncLoginHeadersText),
      loginBody: form.value.configJsonSyncLoginBody || '',
      configUrl: (form.value.configJsonSyncConfigUrl || '').trim(),
      configMethod: form.value.configJsonSyncConfigMethod || 'GET',
      configHeaders: parseObjectText(form.value.configJsonSyncConfigHeadersText),
      configBody: form.value.configJsonSyncConfigBody || '',
      tokenPath: (form.value.configJsonSyncTokenPath || '').trim(),
      tokenHeader: (form.value.configJsonSyncTokenHeader || 'Authorization').trim(),
      tokenPrefix: form.value.configJsonSyncTokenPrefix ?? 'Bearer ',
      configPath: (form.value.configJsonSyncConfigPath || '').trim()
    }
  };
}

function changeConfigEnvironment(next) {
  captureConfigEnvironment(activeConfigEnvironment.value);
  activeConfigEnvironment.value = next;
  applyConfigEnvironment(next);
}

function hasAnyConfigJson(row) {
  return Object.values(configEnvironmentsOf(row)).some((value) => !!String(value.configJson || '').trim());
}

function hasAnyConfigSync(row) {
  return Object.values(configEnvironmentsOf(row)).some((value) => value.configJsonSync?.enabled === true);
}

function regionIdsOf(row) {
  const values = Array.isArray(row?.regions) && row.regions.length > 0
    ? row.regions
    : (row?.region ? [row.region] : []);
  return [...new Set(values.map((id) => String(id || '').trim()).filter(Boolean))];
}

function regionNamesOf(row) {
  const names = { ...(row?.regionNames || {}) };
  if (row?.region && row?.regionName && !names[row.region]) names[row.region] = row.regionName;
  return names;
}

function regionNameOf(row, id) {
  const name = String(regionNamesOf(row)[id] || '').trim();
  if (name && !/^[?\s._()（）-]+$/.test(name)) return name;
  return REGION_NAME_FALLBACKS[id] || `地区 ${id}`;
}

const regionOptions = computed(() => {
  const map = new Map();
  apps.value.forEach((app) => {
    regionIdsOf(app).forEach((id) => {
      const name = regionNameOf(app, id);
      if (!map.has(id) || map.get(id) === id) map.set(id, name);
    });
  });
  return Array.from(map.entries())
    .map(([id, name]) => ({ id, name, label: name === id ? id : `${name} (${id})` }))
    .sort((a, b) => String(a.name).localeCompare(String(b.name)));
});

async function loadBundles() {
  try {
    const responses = await Promise.all(CONFIG_ENVIRONMENT_OPTIONS.map(({ id }) =>
      api.get('/api/admin/bundles', { params: { environment: id } })
    ));
    const m = {};
    responses.forEach(({ data }) => {
      (data || []).forEach((b) => {
        if (!b.builtAt) return;
        const app = apps.value.find((item) => item.id === b.id);
        if (app && bundleEnvironmentOf(app) === b.environment) m[b.id] = b;
      });
    });
    bundleMap.value = m;
  } catch (e) {
    ElMessage.warning('离线包状态刷新失败');
  }
}

onMounted(loadBundles);

function groupOf(row) {
  const scope = row?.scope || 'top';
  if (scope === 'top') return 'top';
  if (scope === 'region') return `region:${regionIdsOf(row)[0] || ''}`;
  return 'top';
}

function appInGroup(app, groupKey) {
  if (groupKey === 'top') return (app?.scope || 'top') !== 'region';
  if (!groupKey?.startsWith('region:') || app?.scope !== 'region') return false;
  return regionIdsOf(app).includes(groupKey.slice('region:'.length));
}

const groupList = computed(() => {
  const regionMap = new Map();
  apps.value.forEach((app) => {
    if ((app.scope || 'top') !== 'region') return;
    regionIdsOf(app).forEach((id) => regionMap.set(id, regionNameOf(app, id)));
  });
  const groups = [
    {
      key: 'top',
      name: 'TOP 常驻',
      desc: 'SDK 初始化后自动下载并长期保留',
      count: apps.value.filter((a) => (a.scope || 'top') !== 'region').length
    }
  ];
  Array.from(regionMap.entries()).sort((a, b) => String(a[1]).localeCompare(String(b[1]))).forEach(([id, name]) => {
    groups.push({
      key: `region:${id}`,
      name: name || id,
      desc: `地区 ${id}`,
      count: apps.value.filter((a) => appInGroup(a, `region:${id}`)).length
    });
  });
  return groups;
});

const activeGroupInfo = computed(() => groupList.value.find((g) => g.key === activeGroup.value) || groupList.value[0]);
const visibleGroupList = computed(() => {
  const q = groupQuery.value.trim().toLowerCase();
  if (!q) return groupList.value;
  return groupList.value.filter((group) =>
    [group.name, group.desc].some((value) => String(value || '').toLowerCase().includes(q))
  );
});
const filteredApps = computed(() => {
  const q = appQuery.value.trim().toLowerCase();
  return apps.value.filter((app) => {
    if (!appInGroup(app, activeGroup.value)) return false;
    if (!q) return true;
    return [
      app.id,
      app.name,
      app.url,
      ...regionIdsOf(app),
      ...Object.values(regionNamesOf(app))
    ].some((v) => String(v || '').toLowerCase().includes(q));
  });
});

const summary = computed(() => {
  const regionSet = new Set();
  let bundleEnabled = 0;
  let jsonCount = 0;
  let readyCount = 0;
  apps.value.forEach((app) => {
    if ((app.scope || 'top') === 'region') regionIdsOf(app).forEach((id) => regionSet.add(id));
    if (app.bundle) bundleEnabled++;
    if (hasAnyConfigJson(app)) jsonCount++;
    if (app.bundle && bundleMap.value[app.id]) readyCount++;
  });
  return {
    total: apps.value.length,
    regions: regionSet.size,
    bundleEnabled,
    readyCount,
    jsonCount
  };
});

const formConfigState = computed(() => inspectConfigJson(form.value.configJson, form.value.url));

function scopeLabel(row) {
  const scope = row?.scope || 'top';
  if (scope === 'region') return regionIdsOf(row).map((id) => regionNameOf(row, id)).join('、') || '地区';
  return 'TOP';
}

function regionItems(row) {
  return regionIdsOf(row).map((id) => ({ id, name: regionNameOf(row, id) }));
}

function visibleRegions(row) {
  return regionItems(row).slice(0, 2);
}

function hiddenRegionCount(row) {
  return Math.max(0, regionIdsOf(row).length - 2);
}

function regionTooltip(row) {
  return regionItems(row).map((item) => `${item.name} (${item.id})`).join('、');
}

function bundleEnvironmentOf(row) {
  const environments = Array.isArray(row?.bundleEnvironments) ? row.bundleEnvironments : [];
  return environments[0] || 'prod';
}

function openBundle(row) {
  router.push({ path: '/bundles', query: { app: row.id, environment: bundleEnvironmentOf(row) } });
}

function emptyForm(groupKey = activeGroup.value) {
  let scope = 'region';
  let region = '';
  let regionName = '';
  if (groupKey === 'top') scope = 'top';
  else if (groupKey && groupKey.startsWith('region:')) {
    scope = 'region';
    region = groupKey.slice('region:'.length);
    regionName = activeGroupInfo.value?.name || region;
  }
  const configJsonEnvironments = configEnvironmentsOf({});
  return {
    id: '',
    name: '',
    url: '',
    scope,
    region,
    regionName,
    regions: region ? [region] : [],
    regionNames: region ? { [region]: regionName || region } : {},
    configJson: '',
    configJsonFileName: '',
    configJsonEnvironments,
    configJsonSyncEnabled: false,
    configJsonSyncLoginUrl: '',
    configJsonSyncLoginMethod: 'POST',
    configJsonSyncLoginHeadersText: '',
    configJsonSyncLoginBody: '',
    configJsonSyncConfigUrl: '',
    configJsonSyncConfigMethod: 'GET',
    configJsonSyncConfigHeadersText: '',
    configJsonSyncConfigBody: '',
    configJsonSyncTokenPath: '',
    configJsonSyncTokenHeader: 'Authorization',
    configJsonSyncTokenPrefix: 'Bearer ',
    configJsonSyncConfigPath: '',
    routesText: '/',
    swrDoc: true,
    prerender: true,
    codeCache: true,
    bundle: true,
    bundleEnvironments: ['test'],
    prefetchChunks: true,
    extraBlockHostsText: '',
    preconnectHostsText: '',
    userAgent: '',
    bundleExtraUrlsText: '',
    bundleExcludeUrlsText: '',
    bundleMaxSizeKB: 5120,
    staticCacheEnabled: true,
    staticCacheMinSizeKB: 64,
    staticCacheMinDurationMs: 800,
    staticCacheMaxSizeKB: 5120,
    staticCacheIncludeText: '',
    staticCacheExcludeText: ''
  };
}

function openAdd() {
  editing.value = null;
  activeDialogTab.value = 'base';
  activeConfigEnvironment.value = 'test';
  form.value = emptyForm();
  dialog.value = true;
}

function openEdit(row) {
  const staticCache = row.staticCache || {};
  const configJsonEnvironments = configEnvironmentsOf(row);
  const configJsonSync = configJsonEnvironments.test.configJsonSync || {};
  editing.value = row.id;
  activeDialogTab.value = 'base';
  activeConfigEnvironment.value = 'test';
  form.value = {
    ...emptyForm(),
    ...row,
    regions: regionIdsOf(row),
    regionNames: regionNamesOf(row),
    configJsonEnvironments,
    configJson: configJsonEnvironments.test.configJson || '',
    configJsonFileName: configJsonEnvironments.test.configJsonFileName || '',
    routesText: (row.routes || []).join('\n'),
    extraBlockHostsText: (row.extraBlockHosts || []).join('\n'),
    preconnectHostsText: (row.preconnectHosts || []).join('\n'),
    bundleExtraUrlsText: (row.bundleExtraUrls || []).join('\n'),
    bundleExcludeUrlsText: (row.bundleExcludeUrls || []).join('\n'),
    bundleMaxSizeKB: row.bundleMaxSizeKB ?? 5120,
    configJsonSyncEnabled: configJsonSync.enabled !== false && (!!configJsonSync.loginUrl || !!configJsonSync.configUrl),
    configJsonSyncLoginUrl: configJsonSync.loginUrl || '',
    configJsonSyncLoginMethod: configJsonSync.loginMethod || 'POST',
    configJsonSyncLoginHeadersText: stringifyObject(configJsonSync.loginHeaders),
    configJsonSyncLoginBody: configJsonSync.loginBody || '',
    configJsonSyncConfigUrl: configJsonSync.configUrl || '',
    configJsonSyncConfigMethod: configJsonSync.configMethod || 'GET',
    configJsonSyncConfigHeadersText: stringifyObject(configJsonSync.configHeaders),
    configJsonSyncConfigBody: configJsonSync.configBody || '',
    configJsonSyncTokenPath: configJsonSync.tokenPath || '',
    configJsonSyncTokenHeader: configJsonSync.tokenHeader || 'Authorization',
    configJsonSyncTokenPrefix: configJsonSync.tokenPrefix ?? 'Bearer ',
    configJsonSyncConfigPath: configJsonSync.configPath || '',
    staticCacheEnabled: staticCache.enabled !== false,
    staticCacheMinSizeKB: staticCache.minSizeKB ?? 64,
    staticCacheMinDurationMs: staticCache.minDurationMs ?? 800,
    staticCacheMaxSizeKB: staticCache.maxSizeKB ?? 5120,
    staticCacheIncludeText: (staticCache.include || []).join('\n'),
    staticCacheExcludeText: (staticCache.exclude || []).join('\n')
  };
  dialog.value = true;
}

async function detect() {
  if (!form.value.url) {
    ElMessage.warning('请先填写 URL');
    return;
  }
  detecting.value = true;
  try {
    const { data } = await api.post('/api/admin/apps/detect', { url: form.value.url });
    if (data && data.ok) {
      if (data.name && !form.value.name) form.value.name = data.name;
      const r = data.recommend || {};
      form.value.swrDoc = r.swrDoc !== false;
      form.value.prerender = r.prerender !== false;
      form.value.bundle = !!r.bundle;
      form.value.codeCache = !!r.codeCache;
      form.value.prefetchChunks = r.prefetchChunks !== false;
      const pc = r.preconnectHosts || data.preconnectHosts || [];
      if (pc.length) form.value.preconnectHostsText = pc.join('\n');
      ElMessage.success(`探测成功: ${data.sameOriginCacheable} 个可缓存资源, ${pc.length} 个预连接域`);
    }
  } catch (e) {
    ElMessage.error('探测失败:' + (e.response?.data?.error || e.message));
  } finally {
    detecting.value = false;
  }
}

function importConfigJson(uploadFile) {
  const raw = uploadFile.raw;
  if (!raw) return false;
  const reader = new FileReader();
  reader.onload = () => {
    form.value.configJson = String(reader.result || '').trim();
    form.value.configJsonFileName = raw.name;
    syncFromConfigJson(false);
    ElMessage.success('已导入 JSON 文件');
  };
  reader.onerror = () => ElMessage.error('JSON 文件读取失败');
  reader.readAsText(raw, 'utf-8');
  return false;
}

function syncFromConfigJson(showMessage = true) {
  const state = inspectConfigJson(form.value.configJson, form.value.url);
  if (!state.data) {
    if (showMessage) ElMessage.warning(state.message);
    return;
  }
  if (state.data.url) form.value.url = String(state.data.url).trim();
  if (state.data.title && !form.value.name) form.value.name = String(state.data.title).trim();
  if (state.data.abilityName && !form.value.id) {
    form.value.id = String(state.data.abilityName).replace(/[^a-zA-Z0-9_-]/g, '').toLowerCase();
  }
  if (showMessage) ElMessage.success('已从 JSON 同步 URL 和名称');
}

function inspectConfigJson(text, appUrl) {
  const raw = String(text || '').trim();
  if (!raw) return { ok: false, empty: true, type: 'info', message: '未导入 JSON', data: null };
  try {
    const data = JSON.parse(raw);
    const configUrl = String(data.url || '').trim();
    if (!configUrl) {
      return { ok: false, type: 'danger', message: 'JSON 缺少 url 字段', data };
    }
    const configOrigin = originOf(configUrl);
    const appOrigin = originOf(appUrl);
    if (!configOrigin) {
      return { ok: false, type: 'danger', message: 'JSON.url 不是有效地址', data };
    }
    if (appOrigin && appOrigin !== configOrigin) {
      return { ok: false, type: 'danger', message: 'JSON.url 与应用 URL 不同源', data };
    }
    return { ok: true, type: 'success', message: 'JSON 可用于 websdk', data };
  } catch (e) {
    return { ok: false, type: 'danger', message: 'JSON 格式错误', data: null };
  }
}

function originOf(input) {
  try {
    return new URL(String(input || '').trim()).origin;
  } catch (e) {
    const match = String(input || '').match(/^https?:\/\/[^/]+/i);
    return match ? match[0] : '';
  }
}

function splitLines(text) {
  return String(text || '').split('\n').map((s) => s.trim()).filter(Boolean);
}

function stringifyObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length === 0) return '';
  return JSON.stringify(value, null, 2);
}

function parseObjectText(text) {
  const raw = String(text || '').trim();
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch (e) {
    const out = {};
    raw.split('\n').forEach((line) => {
      const idx = line.indexOf(':');
      if (idx > 0) out[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
    });
    return out;
  }
}

function bundleOf(row) {
  return bundleMap.value[row.id];
}

function bundleSizeText(row) {
  const b = bundleOf(row);
  const kb = Number(b?.sizeKB || b?.kb || 0);
  if (!kb) return '-';
  if (kb >= 1024) return `${(kb / 1024).toFixed(1)} MB`;
  return `${kb} KB`;
}

function configTag(row) {
  const environments = configEnvironmentsOf(row);
  let valid = 0;
  let invalid = 0;
  CONFIG_ENVIRONMENT_OPTIONS.forEach(({ id }) => {
    const text = environments[id].configJson;
    if (!text) return;
    if (inspectConfigJson(text, row.url).ok) valid++;
    else invalid++;
  });
  if (invalid > 0) return { type: 'danger', text: `${invalid} 个环境异常` };
  if (valid === 0) return { type: 'info', text: '无 JSON' };
  return { type: valid === 3 ? 'success' : 'warning', text: `JSON ${valid}/3` };
}

async function submit() {
  captureConfigEnvironment();
  if (!form.value.id || !form.value.url) {
    ElMessage.warning('ID 和 URL 必填');
    return;
  }
  if (!/^[a-zA-Z0-9_-]+$/.test(form.value.id)) {
    ElMessage.warning('ID 只能包含英文、数字、下划线和短横线');
    return;
  }
  if (!originOf(form.value.url)) {
    ElMessage.warning('URL 必须是 http(s):// 开头的完整地址');
    return;
  }
  const selectedRegions = regionIdsOf({ regions: form.value.regions });
  if (form.value.scope !== 'top' && selectedRegions.length === 0) {
    ElMessage.warning('地区应用必须至少填写一个地区 ID');
    return;
  }
  const configJsonEnvironments = configEnvironmentsOf(form.value);
  if (form.value.bundle && !hasAnyConfigJson(form.value) && !hasAnyConfigSync(form.value)) {
    ElMessage.warning('启用离线包时请至少配置一个环境的 websdk JSON 或自动同步');
    activeDialogTab.value = 'json';
    return;
  }
  if (form.value.bundle && (!Array.isArray(form.value.bundleEnvironments) || form.value.bundleEnvironments.length === 0)) {
    ElMessage.warning('启用离线包时必须至少选择一个离线包环境');
    activeDialogTab.value = 'base';
    return;
  }
  for (const option of CONFIG_ENVIRONMENT_OPTIONS) {
    const text = configJsonEnvironments[option.id].configJson;
    const jsonState = inspectConfigJson(text, form.value.url);
    if (text.trim() && !jsonState.ok) {
      ElMessage.warning(`${option.name}环境：${jsonState.message}`);
      activeConfigEnvironment.value = option.id;
      applyConfigEnvironment(option.id);
      activeDialogTab.value = 'json';
      return;
    }
  }

  const scope = form.value.scope === 'region' ? 'region' : 'top';
  const regionNames = {};
  selectedRegions.forEach((id) => {
    const existingName = String(form.value.regionNames?.[id] || '').trim();
    const option = regionOptions.value.find((item) => item.id === id);
    regionNames[id] = existingName || option?.name || id;
  });
  const item = {
    id: form.value.id.trim(),
    name: form.value.name.trim(),
    url: form.value.url.trim(),
    scope,
    regions: scope === 'region' ? selectedRegions : [],
    regionNames: scope === 'region' ? regionNames : {},
    region: scope === 'region' ? (selectedRegions[0] || '') : '',
    regionName: scope === 'region' && selectedRegions[0] ? regionNames[selectedRegions[0]] : '',
    configJsonEnvironments,
    routes: splitLines(form.value.routesText),
    swrDoc: form.value.swrDoc,
    prerender: form.value.prerender,
    codeCache: form.value.codeCache,
    bundle: form.value.bundle,
    bundleEnvironments: form.value.bundle ? [...form.value.bundleEnvironments] : [],
    prefetchChunks: form.value.prefetchChunks,
    bundleMaxSizeKB: Number(form.value.bundleMaxSizeKB || 0),
    extraBlockHosts: splitLines(form.value.extraBlockHostsText),
    preconnectHosts: splitLines(form.value.preconnectHostsText),
    bundleExtraUrls: splitLines(form.value.bundleExtraUrlsText),
    bundleExcludeUrls: splitLines(form.value.bundleExcludeUrlsText),
    userAgent: (form.value.userAgent || '').trim(),
    staticCache: {
      enabled: form.value.staticCacheEnabled,
      minSizeKB: Number(form.value.staticCacheMinSizeKB || 0),
      minDurationMs: Number(form.value.staticCacheMinDurationMs || 0),
      maxSizeKB: Number(form.value.staticCacheMaxSizeKB || 0),
      include: splitLines(form.value.staticCacheIncludeText),
      exclude: splitLines(form.value.staticCacheExcludeText)
    }
  };

  const previous = [...apps.value];
  const list = [...apps.value];
  const idx = list.findIndex((a) => a.id === editing.value);
  if (idx >= 0) list[idx] = item;
  else list.push(item);

  try {
    apps.value = list;
    const autoBuilding = await store.saveApp(item, editing.value || item.id);
    activeGroup.value = groupOf(item);
    dialog.value = false;
    if (autoBuilding && autoBuilding.includes(item.id)) {
      ElMessage.success(`已保存,正在后台自动构建「${item.name || item.id}」离线包`);
      setTimeout(() => { loadBundles().catch(() => {}); }, 30000);
    } else {
      ElMessage.success('已保存');
      loadBundles().catch(() => {});
    }
  } catch (e) {
    apps.value = previous;
    ElMessage.error('保存失败:' + (e.response?.data?.error || e.message));
  }
}

async function remove(row) {
  await ElMessageBox.confirm(`删除应用「${row.name || row.id}」?`, '确认', { type: 'warning' });
  const previous = [...apps.value];
  try {
    apps.value = apps.value.filter((a) => a.id !== row.id);
    await store.deleteApp(row.id);
    ElMessage.success('已删除');
  } catch (e) {
    apps.value = previous;
    ElMessage.error('删除失败:' + (e.response?.data?.error || e.message));
  }
}

const checking = ref('');
const updating = ref('');
const building = ref('');
const generating = ref('');
const syncingJson = ref('');

function rowBusy(row) {
  return [checking.value, updating.value, building.value, generating.value, syncingJson.value].includes(row.id);
}

function handleRowCommand(command, row) {
  if (command === 'check') return checkUpdate(row);
  if (command === 'update') return updateCache(row);
  if (command === 'sync') return syncConfigJson(row);
  if (command === 'build') return buildCache(row);
  if (command === 'manifest') return generateManifest(row);
  if (command === 'delete') return remove(row);
}

async function checkUpdate(row) {
  checking.value = row.id;
  try {
    const { data } = await api.post(`/api/admin/bundles/${row.id}/check`, { environment: bundleEnvironmentOf(row) });
    if (data.changed) {
      const home = data.homeChanged ? '首页已变化' : '首页未变化';
      ElMessage.warning(`${home}; 新增 ${data.addedCount}, 移除 ${data.removedCount}, 缺失 ${data.missingFileCount}`);
    } else {
      ElMessage.success('未发现更新');
    }
  } catch (e) {
    ElMessage.error('检查失败:' + (e.response?.data?.error || e.message));
  } finally {
    checking.value = '';
  }
}

async function updateCache(row) {
  updating.value = row.id;
  try {
    const { data } = await api.post(`/api/admin/bundles/${row.id}/update`, { environment: bundleEnvironmentOf(row) });
    ElMessage.success(`已增量更新: 下载 ${data.downloaded}, 跳过 ${data.skipped}, 共 ${data.count}`);
    loadBundles().catch(() => {});
  } catch (e) {
    ElMessage.error('增量更新失败:' + (e.response?.data?.error || e.message));
  } finally {
    updating.value = '';
  }
}

async function buildCache(row) {
  await ElMessageBox.confirm('强制重建会访问目标站并清空旧缓存目录,确认继续?', '确认强制重建', { type: 'warning' });
  building.value = row.id;
  try {
    const { data } = await api.post(`/api/admin/bundles/${row.id}/build`, { environment: bundleEnvironmentOf(row) });
    ElMessage.success(`已构建 ${data.count} 个缓存资源`);
    loadBundles().catch(() => {});
  } catch (e) {
    ElMessage.error('构建失败:' + (e.response?.data?.error || e.message));
  } finally {
    building.value = '';
  }
}

async function generateManifest(row) {
  generating.value = row.id;
  try {
    const { data } = await api.post(`/api/admin/bundles/${row.id}/manifest`, { environment: bundleEnvironmentOf(row) });
    ElMessage.success(`已生成 ${data.count} 个缓存资源`);
    loadBundles().catch(() => {});
  } catch (e) {
    ElMessage.error('生成失败:' + (e.response?.data?.error || e.message));
  } finally {
    generating.value = '';
  }
}

async function syncConfigJson(row) {
  syncingJson.value = row.id;
  try {
    const { data } = await api.post('/api/admin/config-json-sync/run', { appId: row.id });
    const results = data?.log?.results || [];
    const failed = results.filter((item) => item.ok === false);
    const changed = results.filter((item) => item.changed === true);
    if (failed.length > 0) {
      ElMessage.error(`JSON 同步失败 ${failed.length} 个环境：` + failed.map((item) => `${item.environmentName}:${item.detail}`).join('；'));
    } else {
      ElMessage.success(changed.length > 0 ? `JSON 已更新 ${changed.length} 个环境` : '三环境 JSON 已检查，无变化');
      await store.load();
    }
  } catch (e) {
    ElMessage.error('JSON 同步失败:' + (e.response?.data?.error || e.message));
  } finally {
    syncingJson.value = '';
  }
}
</script>

<template>
  <div class="apps-page">
    <div class="page-head">
      <div>
        <div class="eyebrow">WebAccel 配置</div>
        <h2>应用管理</h2>
        <p>按 TOP 和地区维护网址、websdk JSON、离线包资源清单。</p>
      </div>
      <div class="head-actions">
        <el-input v-model="appQuery" class="search-input" clearable :prefix-icon="Search" placeholder="搜索 ID / 名称 / URL" />
        <el-button :icon="Refresh" @click="loadBundles">刷新状态</el-button>
        <el-button type="primary" :icon="Plus" @click="openAdd">新增网址</el-button>
      </div>
    </div>

    <div class="summary-grid">
      <div class="summary-item">
        <span>应用总数</span>
        <b>{{ summary.total }}</b>
      </div>
      <div class="summary-item">
        <span>地区数</span>
        <b>{{ summary.regions }}</b>
      </div>
      <div class="summary-item">
        <span>启用离线包</span>
        <b>{{ summary.bundleEnabled }}</b>
      </div>
      <div class="summary-item">
        <span>已构建</span>
        <b>{{ summary.readyCount }}</b>
      </div>
      <div class="summary-item">
        <span>带 JSON</span>
        <b>{{ summary.jsonCount }}</b>
      </div>
    </div>

    <div class="region-layout">
      <aside class="region-pane">
        <div class="pane-title-row">
          <div>
            <div class="pane-title">地区分组</div>
            <div class="pane-subtitle">选择地区查看关联应用</div>
          </div>
          <span class="group-total">{{ groupList.length }}</span>
        </div>
        <el-input v-model="groupQuery" :prefix-icon="Search" clearable size="small" class="group-search"
          placeholder="搜索地区名称或 ID" />
        <div class="group-list">
          <button v-for="g in visibleGroupList" :key="g.key" class="group-item" :class="{ active: activeGroup === g.key }"
            @click="activeGroup = g.key">
            <span>
              <b>{{ g.name }}</b>
              <em>{{ g.desc }}</em>
            </span>
            <span class="group-count">{{ g.count }}</span>
          </button>
          <el-empty v-if="visibleGroupList.length === 0" description="没有匹配地区" :image-size="54" />
        </div>
      </aside>

      <section class="apps-pane">
        <div class="group-head">
          <div>
            <div class="group-title">{{ activeGroupInfo?.name }}</div>
            <div class="muted">{{ activeGroupInfo?.desc }}</div>
          </div>
          <el-tag type="info" effect="plain">{{ filteredApps.length }} 个网址</el-tag>
        </div>

        <el-table :data="filteredApps" row-key="id" class="apps-table" empty-text="当前分组暂无应用" stripe>
          <el-table-column label="应用" min-width="280">
            <template #default="{ row }">
              <div class="app-cell">
                <div class="app-title">
                  <b>{{ row.name || row.id }}</b>
                  <el-tag size="small" effect="plain">{{ row.id }}</el-tag>
                </div>
                <div class="app-url">{{ row.url }}</div>
              </div>
            </template>
          </el-table-column>
          <el-table-column label="所属地区" width="220">
            <template #default="{ row }">
              <div v-if="row.scope === 'region'" class="region-tags">
                <el-tag v-for="item in visibleRegions(row)" :key="item.id" size="small" type="success" effect="light">
                  {{ item.name }}
                </el-tag>
                <el-tooltip v-if="hiddenRegionCount(row)" :content="regionTooltip(row)" placement="top" :show-after="250">
                  <el-tag size="small" type="info" effect="plain" class="more-regions">+{{ hiddenRegionCount(row) }}</el-tag>
                </el-tooltip>
              </div>
              <el-tag v-else size="small" type="info" effect="light">TOP 常驻</el-tag>
              <div v-if="row.scope === 'region'" class="table-sub region-count-text">关联 {{ regionIdsOf(row).length }} 个地区</div>
            </template>
          </el-table-column>
          <el-table-column label="websdk 配置" width="160">
            <template #default="{ row }">
              <el-tag size="small" :type="configTag(row).type" effect="plain">{{ configTag(row).text }}</el-tag>
              <el-tag v-if="hasAnyConfigSync(row)" size="small" type="warning" effect="plain" class="json-sync-tag">多环境同步</el-tag>
            </template>
          </el-table-column>
          <el-table-column label="离线包" width="160">
            <template #default="{ row }">
              <template v-if="bundleOf(row)">
                <el-tag size="small" type="success">已构建</el-tag>
                <div class="table-sub">{{ bundleOf(row).count }} 个 / {{ bundleSizeText(row) }}</div>
              </template>
              <el-tag v-else-if="row.bundle" size="small" type="warning" effect="plain">待构建</el-tag>
              <el-tag v-else size="small" type="info" effect="plain">未启用</el-tag>
            </template>
          </el-table-column>
          <el-table-column label="能力" width="170">
            <template #default="{ row }">
              <div class="tag-row">
                <el-tag v-if="row.bundle" size="small" type="success">离线包</el-tag>
                <el-tag v-if="hasAnyConfigSync(row)" size="small" type="warning" effect="plain">JSON 同步</el-tag>
                <el-tag v-if="row.preconnectHosts?.length" size="small" type="info" effect="plain">预连接 {{ row.preconnectHosts.length }}</el-tag>
              </div>
            </template>
          </el-table-column>
          <el-table-column label="操作" width="270" fixed="right">
            <template #default="{ row }">
              <div class="op-row compact-actions">
                <el-button size="small" type="primary" plain :icon="Box" @click="openBundle(row)">资源</el-button>
                <el-button size="small" :icon="EditPen" @click="openEdit(row)">编辑</el-button>
                <el-dropdown trigger="click" :disabled="rowBusy(row)" @command="(command) => handleRowCommand(command, row)">
                  <el-button size="small" class="more-button" :loading="rowBusy(row)" :icon="MoreFilled">更多</el-button>
                  <template #dropdown>
                    <el-dropdown-menu>
                      <el-dropdown-item command="check">检查资源更新</el-dropdown-item>
                      <el-dropdown-item command="update">增量更新离线包</el-dropdown-item>
                      <el-dropdown-item v-if="hasAnyConfigSync(row)" command="sync">同步三环境 JSON</el-dropdown-item>
                      <el-dropdown-item command="build" divided>强制重建离线包</el-dropdown-item>
                      <el-dropdown-item command="manifest">重新生成清单</el-dropdown-item>
                      <el-dropdown-item command="delete" divided class="danger-menu-item">删除应用</el-dropdown-item>
                    </el-dropdown-menu>
                  </template>
                </el-dropdown>
              </div>
            </template>
          </el-table-column>
        </el-table>
      </section>
    </div>

    <el-dialog v-model="dialog" :title="editing ? '编辑网址应用' : '新增网址应用'" width="960px" destroy-on-close>
      <div class="dialog-head">
        <div>
          <b>{{ form.name || form.id || '未命名应用' }}</b>
          <span>{{ form.url || 'https://...' }}</span>
        </div>
        <el-tag :type="formConfigState.type" effect="plain">{{ formConfigState.message }}</el-tag>
      </div>

      <el-form label-position="top" class="edit-form">
        <el-tabs v-model="activeDialogTab">
          <el-tab-pane label="基础信息" name="base">
            <div class="form-grid two">
              <el-form-item label="ID">
                <el-input v-model="form.id" :disabled="!!editing" placeholder="beacukai" />
              </el-form-item>
              <el-form-item label="名称">
                <el-input v-model="form.name" placeholder="印尼出境卡" />
              </el-form-item>
            </div>
            <el-form-item label="URL">
              <div class="inline-control">
                <el-input v-model="form.url" placeholder="https://..." />
                <el-button :loading="detecting" @click="detect">一键探测</el-button>
              </div>
            </el-form-item>
            <div class="form-grid two">
              <el-form-item label="分组">
                <el-radio-group v-model="form.scope">
                  <el-radio-button label="top">TOP 常驻</el-radio-button>
                  <el-radio-button label="region">地区应用</el-radio-button>
                </el-radio-group>
              </el-form-item>
              <el-form-item label="地区 ID（可多选）" v-if="form.scope === 'region'">
                <el-select v-model="form.regions" multiple filterable allow-create default-first-option
                  :reserve-keyword="false" placeholder="选择已有地区或直接输入地区 ID" class="region-select">
                  <el-option v-for="option in regionOptions" :key="option.id" :label="option.label" :value="option.id" />
                </el-select>
              </el-form-item>
            </div>
            <div v-if="form.scope === 'region'" class="field-hint">同一环境内的多个地区可共用该环境离线包；测试、预发、正式仍分别保存和下发。</div>
            <el-form-item label="路由">
              <el-input v-model="form.routesText" type="textarea" :rows="3" placeholder="每行一个路径,例如 /" />
            </el-form-item>
            <el-form-item label="加速项">
              <div class="check-grid">
                <el-checkbox v-model="form.bundle">离线包</el-checkbox>
                <el-checkbox v-model="form.prerender">离屏预渲染</el-checkbox>
                <el-checkbox v-model="form.swrDoc">主文档 SWR</el-checkbox>
                <el-checkbox v-model="form.codeCache">字节码缓存</el-checkbox>
                <el-checkbox v-model="form.prefetchChunks">chunk 预取</el-checkbox>
              </div>
            </el-form-item>
            <el-form-item v-if="form.bundle" label="离线包环境">
              <el-checkbox-group v-model="form.bundleEnvironments">
                <el-checkbox v-for="option in CONFIG_ENVIRONMENT_OPTIONS" :key="option.id" :label="option.id">
                  {{ option.name }}
                </el-checkbox>
              </el-checkbox-group>
              <div class="field-hint">仅所选环境会下发该应用的 manifest，资源文件也存放在独立环境目录。</div>
            </el-form-item>
          </el-tab-pane>

          <el-tab-pane label="websdk JSON" name="json">
            <div class="json-toolbar">
              <b>配置环境</b>
              <el-radio-group :model-value="activeConfigEnvironment" @change="changeConfigEnvironment">
                <el-radio-button v-for="option in CONFIG_ENVIRONMENT_OPTIONS" :key="option.id" :label="option.id">
                  {{ option.name }}
                </el-radio-button>
              </el-radio-group>
              <span class="muted">configJson 与离线包都按环境隔离；此处维护所选环境的 configJson 与拉取账号。</span>
            </div>
            <div class="json-toolbar">
              <el-upload accept=".json,application/json" :auto-upload="false" :show-file-list="false" :on-change="importConfigJson">
                <el-button :icon="Upload">导入 JSON 文件</el-button>
              </el-upload>
              <el-button @click="syncFromConfigJson()">同步 URL/名称</el-button>
              <el-tag :type="formConfigState.type" effect="plain">{{ formConfigState.message }}</el-tag>
              <span v-if="form.configJsonFileName" class="file-name">{{ form.configJsonFileName }}</span>
            </div>
            <el-form-item label="配置 JSON">
              <el-input v-model="form.configJson" type="textarea" :rows="18"
                placeholder='粘贴 websdk 配置 JSON,必须包含 "url" 字段并与应用 URL 同源' />
            </el-form-item>
            <div class="sync-panel">
              <div class="sync-title">
                <b>{{ activeConfigEnvironmentName }}环境：每天 12:00 自动同步</b>
                <el-switch v-model="form.configJsonSyncEnabled" active-text="开启" inactive-text="关闭" />
              </div>
              <div v-if="form.configJsonSyncEnabled">
                <div class="form-grid two">
                  <el-form-item label="登录接口 URL">
                    <el-input v-model="form.configJsonSyncLoginUrl" placeholder="https://example.com/api/login" />
                  </el-form-item>
                  <el-form-item label="登录方法">
                    <el-radio-group v-model="form.configJsonSyncLoginMethod">
                      <el-radio-button label="POST">POST</el-radio-button>
                      <el-radio-button label="GET">GET</el-radio-button>
                    </el-radio-group>
                  </el-form-item>
                </div>
                <el-form-item label="登录 Headers">
                  <el-input v-model="form.configJsonSyncLoginHeadersText" type="textarea" :rows="3"
                    placeholder='JSON 对象或每行 Header: Value' />
                </el-form-item>
                <el-form-item label="登录 Body">
                  <el-input v-model="form.configJsonSyncLoginBody" type="textarea" :rows="4"
                    placeholder='例如 {"username":"...","password":"..."}；保存后敏感内容会掩码显示' />
                </el-form-item>
                <div class="form-grid two">
                  <el-form-item label="配置接口 URL">
                    <el-input v-model="form.configJsonSyncConfigUrl" placeholder="https://example.com/api/config" />
                  </el-form-item>
                  <el-form-item label="配置接口方法">
                    <el-radio-group v-model="form.configJsonSyncConfigMethod">
                      <el-radio-button label="GET">GET</el-radio-button>
                      <el-radio-button label="POST">POST</el-radio-button>
                    </el-radio-group>
                  </el-form-item>
                </div>
                <el-form-item label="配置接口 Headers">
                  <el-input v-model="form.configJsonSyncConfigHeadersText" type="textarea" :rows="3"
                    placeholder='JSON 对象或每行 Header: Value；可留空继承登录 cookie' />
                </el-form-item>
                <el-form-item label="配置接口 Body">
                  <el-input v-model="form.configJsonSyncConfigBody" type="textarea" :rows="3"
                    placeholder="配置接口是 POST 时填写" />
                </el-form-item>
                <div class="form-grid three">
                  <el-form-item label="登录 token 路径">
                    <el-input v-model="form.configJsonSyncTokenPath" placeholder="data.token；留空只用 cookie" />
                  </el-form-item>
                  <el-form-item label="token Header">
                    <el-input v-model="form.configJsonSyncTokenHeader" placeholder="Authorization" />
                  </el-form-item>
                  <el-form-item label="token 前缀">
                    <el-input v-model="form.configJsonSyncTokenPrefix" placeholder="Bearer " />
                  </el-form-item>
                </div>
                <el-form-item label="配置 JSON 路径">
                  <el-input v-model="form.configJsonSyncConfigPath" placeholder="data.config；留空使用完整响应作为 config.json" />
                </el-form-item>
              </div>
            </div>
          </el-tab-pane>

          <el-tab-pane label="离线包资源" name="bundle">
            <div class="form-grid two">
              <el-form-item label="离线包上限 KB">
                <el-input-number v-model="form.bundleMaxSizeKB" :min="0" :max="204800" :step="512" controls-position="right" />
              </el-form-item>
              <el-form-item label="预连接域">
                <el-input v-model="form.preconnectHostsText" type="textarea" :rows="4" placeholder="每行一个域名或 origin" />
              </el-form-item>
            </div>
            <div class="form-grid two">
              <el-form-item label="固定资源">
                <el-input v-model="form.bundleExtraUrlsText" type="textarea" :rows="10" placeholder="每行一个必须进离线包的静态资源 URL" />
              </el-form-item>
              <el-form-item label="排除资源">
                <el-input v-model="form.bundleExcludeUrlsText" type="textarea" :rows="10" placeholder="每行一个不进离线包的资源 URL" />
              </el-form-item>
            </div>
            <el-form-item label="额外黑名单">
              <el-input v-model="form.extraBlockHostsText" type="textarea" :rows="3" placeholder="每行一个只对本应用生效的屏蔽域" />
            </el-form-item>
          </el-tab-pane>

          <el-tab-pane label="缓存策略" name="cache">
            <el-form-item label="静态缓存">
              <el-switch v-model="form.staticCacheEnabled" active-text="启用" inactive-text="关闭" />
            </el-form-item>
            <el-form-item label="缓存阈值">
              <div class="threshold-grid">
                <div>
                  <span>最小体积 KB</span>
                  <el-input-number v-model="form.staticCacheMinSizeKB" :min="0" :max="20480" :step="16" controls-position="right" />
                </div>
                <div>
                  <span>最小耗时 ms</span>
                  <el-input-number v-model="form.staticCacheMinDurationMs" :min="0" :max="30000" :step="100" controls-position="right" />
                </div>
                <div>
                  <span>单资源最大 KB</span>
                  <el-input-number v-model="form.staticCacheMaxSizeKB" :min="0" :max="51200" :step="256" controls-position="right" />
                </div>
              </div>
            </el-form-item>
            <div class="form-grid two">
              <el-form-item label="强制缓存">
                <el-input v-model="form.staticCacheIncludeText" type="textarea" :rows="5" placeholder="每行一个 URL 子串或 * 通配" />
              </el-form-item>
              <el-form-item label="禁止缓存">
                <el-input v-model="form.staticCacheExcludeText" type="textarea" :rows="5" placeholder="每行一个 URL 子串或 * 通配" />
              </el-form-item>
            </div>
            <el-form-item label="自定义 UA">
              <el-input v-model="form.userAgent" type="textarea" :rows="4" placeholder="留空使用默认 UA" />
            </el-form-item>
          </el-tab-pane>
        </el-tabs>
      </el-form>

      <template #footer>
        <el-button @click="dialog = false">取消</el-button>
        <el-button type="primary" @click="submit">保存配置</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.apps-page {
  display: flex;
  flex-direction: column;
  gap: 18px;
}
.page-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
  padding: 22px 24px;
  background: linear-gradient(135deg, #ffffff 0%, #f7f8ff 100%);
  border: 1px solid #e7eaf5;
  border-radius: 14px;
  box-shadow: 0 8px 24px rgba(31, 36, 51, .05);
}
.eyebrow {
  font-size: 12px;
  font-weight: 700;
  color: #4f5bd5;
}
.page-head h2 {
  margin: 4px 0 6px;
  font-size: 22px;
  line-height: 1.2;
}
.page-head p {
  margin: 0;
  color: #747b8f;
  font-size: 13px;
}
.head-actions {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 10px;
  flex-wrap: wrap;
}
.search-input {
  width: 260px;
}
.summary-grid {
  display: grid;
  grid-template-columns: repeat(5, minmax(120px, 1fr));
  gap: 12px;
}
.summary-item {
  background: #fff;
  border: 1px solid #e9ecf4;
  border-radius: 12px;
  padding: 16px 18px;
  box-shadow: 0 4px 14px rgba(31, 36, 51, .035);
  position: relative;
  overflow: hidden;
}
.summary-item::before {
  content: '';
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  width: 3px;
  background: linear-gradient(180deg, #4f5bd5, #7c3aed);
}
.summary-item span {
  display: block;
  color: #747b8f;
  font-size: 12px;
}
.summary-item b {
  display: block;
  margin-top: 8px;
  font-size: 24px;
  line-height: 1;
}
.region-layout {
  display: grid;
  grid-template-columns: 280px minmax(0, 1fr);
  gap: 16px;
}
.region-pane,
.apps-pane {
  border: 1px solid #edf0f6;
  border-radius: 14px;
  background: #fff;
  min-width: 0;
  box-shadow: 0 6px 20px rgba(31, 36, 51, .04);
}
.region-pane {
  padding: 16px 12px 12px;
  align-self: start;
  position: sticky;
  top: 0;
}
.apps-pane {
  padding: 18px;
}
.pane-title {
  font-size: 15px;
  font-weight: 700;
  color: #303445;
}
.pane-title-row {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 12px;
  padding: 0 4px;
}
.pane-subtitle {
  margin-top: 3px;
  color: #959bad;
  font-size: 11px;
}
.group-total,
.group-count {
  min-width: 26px;
  height: 24px;
  padding: 0 7px;
  border-radius: 999px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: #68708a;
  background: #f0f2f8;
  font-size: 12px;
  font-weight: 700;
}
.group-search {
  margin: 14px 0 10px;
}
.group-list {
  max-height: calc(100vh - 390px);
  min-height: 220px;
  overflow-y: auto;
  padding-right: 3px;
}
.group-item {
  width: 100%;
  border: 1px solid transparent;
  background: transparent;
  border-radius: 10px;
  padding: 11px 10px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  cursor: pointer;
  text-align: left;
  color: #303133;
}
.group-item:hover {
  background: #f6f7fb;
}
.group-item.active {
  border-color: #cbd0f6;
  background: linear-gradient(135deg, #f0f2ff 0%, #f7f3ff 100%);
  box-shadow: inset 3px 0 0 #5964dc;
}
.group-item.active .group-count {
  color: #fff;
  background: #5964dc;
}
.group-item b {
  display: block;
  font-size: 14px;
}
.group-item em {
  display: block;
  font-style: normal;
  color: #8a90a2;
  font-size: 12px;
  margin-top: 3px;
}
.group-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 12px;
  padding-bottom: 14px;
  border-bottom: 1px solid #edf0f6;
}
.group-title {
  font-size: 18px;
  font-weight: 700;
  color: #303133;
}
.apps-table {
  margin-top: 4px;
  --el-table-row-hover-bg-color: #f7f8ff;
}
.apps-table :deep(.el-table__cell) {
  padding: 14px 0;
}
.apps-table :deep(th.el-table__cell) {
  padding: 11px 0;
  background: #fafbfe;
  color: #656c80;
  font-size: 12px;
}
.app-cell {
  min-width: 0;
}
.app-title {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.app-title b {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.app-url,
.table-sub {
  margin-top: 4px;
  color: #8a90a2;
  font-size: 12px;
  line-height: 1.35;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.app-url {
  max-width: 420px;
}
.region-tags {
  display: flex;
  align-items: center;
  gap: 5px;
  flex-wrap: nowrap;
}
.region-tags .el-tag {
  max-width: 78px;
  overflow: hidden;
  text-overflow: ellipsis;
}
.region-tags .more-regions {
  flex: none;
  max-width: none;
  cursor: help;
}
.region-count-text {
  color: #a0a6b5;
}
.tag-row,
.op-row {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 6px;
}
.compact-actions {
  flex-wrap: nowrap;
}
.compact-actions .el-button + .el-button {
  margin-left: 0;
}
.more-button {
  min-width: 70px;
}
:global(.danger-menu-item) {
  color: #e34d59 !important;
}
.dialog-head {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  align-items: flex-start;
  padding: 12px 14px;
  border: 1px solid #edf0f6;
  border-radius: 8px;
  background: #f8fafc;
  margin-bottom: 12px;
}
.dialog-head b {
  display: block;
  font-size: 15px;
}
.dialog-head span {
  display: block;
  margin-top: 4px;
  color: #747b8f;
  font-size: 12px;
  word-break: break-all;
}
.edit-form :deep(.el-tabs__content) {
  padding-top: 8px;
}
.form-grid.two {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: 12px;
}
.form-grid.three {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 12px;
}
.inline-control,
.json-toolbar {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
}
.region-select {
  width: 100%;
}
.field-hint {
  margin: -4px 0 14px;
  color: #747b8f;
  font-size: 12px;
  line-height: 1.5;
}
.json-toolbar {
  flex-wrap: wrap;
  margin-bottom: 12px;
}
.file-name {
  color: #747b8f;
  font-size: 12px;
}
.json-sync-tag {
  margin-left: 4px;
}
.sync-panel {
  border: 1px solid #edf0f6;
  border-radius: 8px;
  padding: 14px;
  background: #fafbfe;
}
.sync-title {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 12px;
}
.sync-title b {
  font-size: 14px;
}
.check-grid {
  display: grid;
  grid-template-columns: repeat(5, minmax(120px, 1fr));
  gap: 8px 14px;
  width: 100%;
}
.threshold-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 12px;
  width: 100%;
}
.threshold-grid span {
  display: block;
  margin-bottom: 6px;
  color: #747b8f;
  font-size: 12px;
}
@media (max-width: 1100px) {
  .summary-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
  .region-layout,
  .form-grid.two,
  .form-grid.three,
  .threshold-grid {
    grid-template-columns: 1fr;
  }
  .region-pane {
    position: static;
  }
  .group-list {
    max-height: 320px;
  }
  .page-head {
    flex-direction: column;
  }
  .head-actions,
  .search-input {
    width: 100%;
  }
  .check-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}
</style>
