<script setup>
import { ref, onMounted, computed } from 'vue';
import { storeToRefs } from 'pinia';
import { ElMessage, ElMessageBox } from 'element-plus';
import { Plus, Refresh, Search, Upload } from '@element-plus/icons-vue';
import api from '../api';
import { useConfigStore } from '../stores/config';

const store = useConfigStore();
const { apps } = storeToRefs(store);

const dialog = ref(false);
const editing = ref(null);
const activeGroup = ref('top');
const activeDialogTab = ref('base');
const appQuery = ref('');
const form = ref(emptyForm());
const detecting = ref(false);

const bundleMap = ref({});

async function loadBundles() {
  try {
    const { data } = await api.get('/api/admin/bundles');
    const m = {};
    (data || []).forEach((b) => { m[b.id] = b; });
    bundleMap.value = m;
  } catch (e) {
    ElMessage.warning('离线包状态刷新失败');
  }
}

onMounted(loadBundles);

function groupOf(row) {
  const scope = row?.scope || 'top';
  if (scope === 'top') return 'top';
  if (scope === 'region') return `region:${row.region || ''}`;
  return 'top';
}

const groupList = computed(() => {
  const regionMap = new Map();
  apps.value.forEach((app) => {
    if ((app.scope || 'top') === 'region' && app.region) {
      regionMap.set(app.region, app.regionName || app.region);
    }
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
      count: apps.value.filter((a) => (a.scope || 'top') === 'region' && a.region === id).length
    });
  });
  return groups;
});

const activeGroupInfo = computed(() => groupList.value.find((g) => g.key === activeGroup.value) || groupList.value[0]);
const filteredApps = computed(() => {
  const q = appQuery.value.trim().toLowerCase();
  return apps.value.filter((app) => {
    if (groupOf(app) !== activeGroup.value) return false;
    if (!q) return true;
    return [
      app.id,
      app.name,
      app.url,
      app.region,
      app.regionName
    ].some((v) => String(v || '').toLowerCase().includes(q));
  });
});

const summary = computed(() => {
  const regionSet = new Set();
  let bundleEnabled = 0;
  let jsonCount = 0;
  let readyCount = 0;
  apps.value.forEach((app) => {
    if ((app.scope || 'top') === 'region' && app.region) regionSet.add(app.region);
    if (app.bundle) bundleEnabled++;
    if (app.configJson) jsonCount++;
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
  if (scope === 'region') return row.regionName || row.region || '地区';
  return 'TOP';
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
  return {
    id: '',
    name: '',
    url: '',
    scope,
    region,
    regionName,
    configJson: '',
    configJsonFileName: '',
    routesText: '/',
    swrDoc: true,
    prerender: true,
    codeCache: true,
    bundle: true,
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
  form.value = emptyForm();
  dialog.value = true;
}

function openEdit(row) {
  const staticCache = row.staticCache || {};
  editing.value = row.id;
  activeDialogTab.value = 'base';
  form.value = {
    ...emptyForm(),
    ...row,
    routesText: (row.routes || []).join('\n'),
    extraBlockHostsText: (row.extraBlockHosts || []).join('\n'),
    preconnectHostsText: (row.preconnectHosts || []).join('\n'),
    bundleExtraUrlsText: (row.bundleExtraUrls || []).join('\n'),
    bundleExcludeUrlsText: (row.bundleExcludeUrls || []).join('\n'),
    bundleMaxSizeKB: row.bundleMaxSizeKB ?? 5120,
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
  if (!row.configJson) return { type: 'info', text: '无 JSON' };
  const state = inspectConfigJson(row.configJson, row.url);
  return state.ok ? { type: 'success', text: 'JSON 正常' } : { type: 'danger', text: state.message };
}

async function submit() {
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
  if (form.value.scope !== 'top' && !form.value.region) {
    ElMessage.warning('地区应用必须填写地区 ID');
    return;
  }
  if (form.value.bundle && !form.value.configJson.trim()) {
    ElMessage.warning('启用离线包时请填写或导入 websdk 配置 JSON');
    activeDialogTab.value = 'json';
    return;
  }
  const jsonState = inspectConfigJson(form.value.configJson, form.value.url);
  if (form.value.configJson.trim() && !jsonState.ok) {
    ElMessage.warning(jsonState.message);
    activeDialogTab.value = 'json';
    return;
  }

  const scope = form.value.scope === 'region' ? 'region' : 'top';
  const item = {
    id: form.value.id.trim(),
    name: form.value.name.trim(),
    url: form.value.url.trim(),
    scope,
    region: scope === 'region' ? (form.value.region || '').trim() : '',
    regionName: scope === 'region' ? (form.value.regionName || '').trim() : '',
    configJson: (form.value.configJson || '').trim(),
    configJsonFileName: (form.value.configJsonFileName || '').trim(),
    routes: splitLines(form.value.routesText),
    swrDoc: form.value.swrDoc,
    prerender: form.value.prerender,
    codeCache: form.value.codeCache,
    bundle: form.value.bundle,
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
    const autoBuilding = await store.saveApps();
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
    await store.saveApps();
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

async function checkUpdate(row) {
  checking.value = row.id;
  try {
    const { data } = await api.post(`/api/admin/bundles/${row.id}/check`);
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
    const { data } = await api.post(`/api/admin/bundles/${row.id}/update`);
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
    const { data } = await api.post(`/api/admin/bundles/${row.id}/build`);
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
    const { data } = await api.post(`/api/admin/bundles/${row.id}/manifest`);
    ElMessage.success(`已生成 ${data.count} 个缓存资源`);
    loadBundles().catch(() => {});
  } catch (e) {
    ElMessage.error('生成失败:' + (e.response?.data?.error || e.message));
  } finally {
    generating.value = '';
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
        <div class="pane-title">地区分组</div>
        <button v-for="g in groupList" :key="g.key" class="group-item" :class="{ active: activeGroup === g.key }"
          @click="activeGroup = g.key">
          <span>
            <b>{{ g.name }}</b>
            <em>{{ g.desc }}</em>
          </span>
          <el-tag size="small" type="info" effect="plain">{{ g.count }}</el-tag>
        </button>
      </aside>

      <section class="apps-pane">
        <div class="group-head">
          <div>
            <div class="group-title">{{ activeGroupInfo?.name }}</div>
            <div class="muted">{{ activeGroupInfo?.desc }}</div>
          </div>
          <el-tag type="info" effect="plain">{{ filteredApps.length }} 个网址</el-tag>
        </div>

        <el-table :data="filteredApps" row-key="id" class="apps-table" empty-text="当前分组暂无应用">
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
          <el-table-column label="分组" width="150">
            <template #default="{ row }">
              <el-tag size="small" :type="row.scope === 'region' ? 'success' : 'info'" effect="plain">{{ scopeLabel(row) }}</el-tag>
              <div v-if="row.scope === 'region'" class="table-sub">{{ row.region }}</div>
            </template>
          </el-table-column>
          <el-table-column label="websdk 配置" width="160">
            <template #default="{ row }">
              <el-tag size="small" :type="configTag(row).type" effect="plain">{{ configTag(row).text }}</el-tag>
              <div v-if="row.configJsonFileName" class="table-sub">{{ row.configJsonFileName }}</div>
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
          <el-table-column label="加速项" width="190">
            <template #default="{ row }">
              <div class="tag-row">
                <el-tag v-if="row.bundle" size="small" type="success">离线包</el-tag>
                <el-tag v-if="row.prerender" size="small">预渲染</el-tag>
                <el-tag v-if="row.swrDoc" size="small">SWR</el-tag>
                <el-tag v-if="row.codeCache" size="small">字节码</el-tag>
                <el-tag v-if="row.prefetchChunks" size="small" type="info">预取</el-tag>
              </div>
            </template>
          </el-table-column>
          <el-table-column label="操作" width="370" fixed="right">
            <template #default="{ row }">
              <div class="op-row">
                <el-button size="small" link type="primary" :loading="checking === row.id" @click="checkUpdate(row)">检查</el-button>
                <el-button size="small" link type="primary" :loading="updating === row.id" @click="updateCache(row)">更新</el-button>
                <el-button size="small" link type="primary" :loading="building === row.id" @click="buildCache(row)">重建</el-button>
                <el-button size="small" link type="primary" :loading="generating === row.id" @click="generateManifest(row)">清单</el-button>
                <el-button size="small" @click="openEdit(row)">编辑</el-button>
                <el-button size="small" type="danger" plain @click="remove(row)">删除</el-button>
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
              <el-form-item label="地区 ID" v-if="form.scope === 'region'">
                <el-input v-model="form.region" placeholder="1988526837953462273" />
              </el-form-item>
              <el-form-item label="地区名称" v-if="form.scope === 'region'">
                <el-input v-model="form.regionName" placeholder="印度尼西亚" />
              </el-form-item>
            </div>
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
          </el-tab-pane>

          <el-tab-pane label="websdk JSON" name="json">
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
  gap: 16px;
}
.page-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
  padding: 18px 20px;
  background: #fff;
  border: 1px solid #edf0f6;
  border-radius: 8px;
  box-shadow: 0 2px 10px rgba(31, 36, 51, .04);
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
  border: 1px solid #edf0f6;
  border-radius: 8px;
  padding: 14px 16px;
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
  grid-template-columns: 260px minmax(0, 1fr);
  gap: 16px;
}
.region-pane,
.apps-pane {
  border: 1px solid #edf0f6;
  border-radius: 8px;
  background: #fff;
  min-width: 0;
  box-shadow: 0 2px 10px rgba(31, 36, 51, .04);
}
.region-pane {
  padding: 12px;
  align-self: start;
}
.apps-pane {
  padding: 14px;
}
.pane-title {
  font-size: 13px;
  font-weight: 700;
  color: #606266;
  margin-bottom: 10px;
}
.group-item {
  width: 100%;
  border: 1px solid transparent;
  background: transparent;
  border-radius: 8px;
  padding: 10px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  cursor: pointer;
  text-align: left;
  color: #303133;
}
.group-item:hover {
  background: #f6f8fc;
}
.group-item.active {
  border-color: #bfc6f2;
  background: #f1f4ff;
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
}
.group-title {
  font-size: 18px;
  font-weight: 700;
  color: #303133;
}
.apps-table {
  margin-top: 14px;
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
  word-break: break-all;
}
.tag-row,
.op-row {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 6px;
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
.inline-control,
.json-toolbar {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
}
.json-toolbar {
  flex-wrap: wrap;
  margin-bottom: 12px;
}
.file-name {
  color: #747b8f;
  font-size: 12px;
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
  .threshold-grid {
    grid-template-columns: 1fr;
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
