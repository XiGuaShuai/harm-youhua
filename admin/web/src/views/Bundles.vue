<script setup>
import { ref, onMounted, computed, watch } from 'vue';
import { useRoute } from 'vue-router';
import { ElMessage } from 'element-plus';
import { Search, Upload } from '@element-plus/icons-vue';
import api from '../api';

const route = useRoute();
const bundles = ref([]);
const loading = ref(false);
const selectedId = ref('');
const resourceFilter = ref('all');
const groupFilter = ref('all');
const siteQuery = ref('');
const resourceQuery = ref('');
const togglingKey = ref('');
const importDialog = ref(false);
const importText = ref('');
const importing = ref(false);
const importResults = ref([]);
const configDialog = ref(false);
const configText = ref('');
const configFileName = ref('');
const configSaving = ref(false);

const autoLog = ref(null);
const autoRunning = ref(false);
const triggering = ref(false);

async function load() {
  loading.value = true;
  try {
    const { data } = await api.get('/api/admin/bundles');
    bundles.value = Array.isArray(data) ? data : [];
    const requestedId = typeof route.query.app === 'string' ? route.query.app : '';
    if (requestedId && bundles.value.some((b) => b.id === requestedId)) {
      selectedId.value = requestedId;
    } else if (!selectedId.value || !bundles.value.some((b) => b.id === selectedId.value)) {
      selectedId.value = bundles.value[0]?.id || '';
    }
  } finally {
    loading.value = false;
  }
  loadAutoLog();
}
onMounted(load);

watch(() => route.query.app, (appId) => {
  if (typeof appId === 'string' && bundles.value.some((bundle) => bundle.id === appId)) {
    selectedId.value = appId;
  }
});

watch(groupFilter, () => {
  if (!filteredBundles.value.some((b) => b.id === selectedId.value)) {
    selectedId.value = filteredBundles.value[0]?.id || '';
  }
});

async function loadAutoLog() {
  try {
    const { data } = await api.get('/api/admin/auto-update/log');
    autoLog.value = data.log;
    autoRunning.value = data.running;
  } catch (e) { /* ignore */ }
}

async function runAutoUpdate() {
  triggering.value = true;
  try {
    await api.post('/api/admin/auto-update/run');
    ElMessage.success('已触发后台检查');
    autoRunning.value = true;
    setTimeout(() => { loadAutoLog(); load(); }, 6000);
  } catch (e) {
    ElMessage.error('触发失败:' + (e.response?.data?.error || e.message));
  } finally {
    triggering.value = false;
  }
}

const selected = computed(() => bundles.value.find((b) => b.id === selectedId.value) || null);

function regionIdsOf(row) {
  const config = row?.config || {};
  const values = Array.isArray(row?.regions) && row.regions.length > 0
    ? row.regions
    : (Array.isArray(config.regions) && config.regions.length > 0
      ? config.regions
      : (row?.region || config.region ? [row?.region || config.region] : []));
  return [...new Set(values.map((id) => String(id || '').trim()).filter(Boolean))];
}

function regionNameOf(row, id) {
  const config = row?.config || {};
  const names = { ...(config.regionNames || {}), ...(row?.regionNames || {}) };
  if (row?.region === id && row?.regionName) return row.regionName;
  if (config.region === id && config.regionName) return config.regionName;
  return names[id] || id;
}

function groupKeys(row) {
  const scope = row?.scope || row?.config?.scope || 'top';
  if (scope !== 'region') return ['top'];
  return regionIdsOf(row).map((id) => `region:${id}`);
}

function groupName(row) {
  const scope = row?.scope || row?.config?.scope || 'top';
  if (scope === 'region') return regionIdsOf(row).map((id) => regionNameOf(row, id)).join('、') || '地区';
  return 'TOP';
}

function shortGroupName(row) {
  const scope = row?.scope || row?.config?.scope || 'top';
  if (scope !== 'region') return 'TOP 常驻';
  const ids = regionIdsOf(row);
  if (!ids.length) return '地区';
  const first = regionNameOf(row, ids[0]);
  return ids.length > 1 ? `${first} +${ids.length - 1}` : first;
}

const groupOptions = computed(() => {
  const map = new Map();
  map.set('all', '全部');
  map.set('top', 'TOP 常驻');
  bundles.value.forEach((b) => {
    groupKeys(b).forEach((key) => {
      if (key.startsWith('region:') && !map.has(key)) {
        const id = key.slice('region:'.length);
        map.set(key, regionNameOf(b, id));
      }
    });
  });
  return Array.from(map.entries()).map(([value, label]) => ({ value, label }));
});

const filteredBundles = computed(() => {
  const q = siteQuery.value.trim().toLowerCase();
  return bundles.value.filter((bundle) => {
    if (groupFilter.value !== 'all' && !groupKeys(bundle).includes(groupFilter.value)) return false;
    if (!q) return true;
    return [bundle.id, bundle.name, bundle.url, groupName(bundle)]
      .some((value) => String(value || '').toLowerCase().includes(q));
  });
});

const resources = computed(() => {
  const list = selected.value?.resources || [];
  const q = resourceQuery.value.trim().toLowerCase();
  return list
    .filter((r) => {
      if (q && ![r.file, r.url, r.mime].some((value) => String(value || '').toLowerCase().includes(q))) return false;
      if (resourceFilter.value === 'enabled') return r.enabled !== false && r.inManifest !== false;
      if (resourceFilter.value === 'disabled') return r.enabled === false;
      if (resourceFilter.value === 'large') return Number(r.size || 0) >= 64 * 1024;
      if (resourceFilter.value === 'slow') return Number(r.costMs || 0) >= 800;
      return true;
    })
    .slice()
    .sort((a, b) => {
      const ea = a.enabled === false ? 1 : 0;
      const eb = b.enabled === false ? 1 : 0;
      if (ea !== eb) return ea - eb;
      return Number(b.size || 0) - Number(a.size || 0);
    });
});

function selectSite(row) {
  selectedId.value = row.id;
}

function manifestLink(row) {
  return location.origin + row.manifestUrl;
}

function copyManifest(row) {
  navigator.clipboard.writeText(manifestLink(row));
  ElMessage.success('已复制 manifest 地址');
}

function formatSize(bytes) {
  const n = Number(bytes || 0);
  if (n >= 1024 * 1024) return `${(n / 1024 / 1024).toFixed(2)} MB`;
  if (n > 0) return `${(n / 1024).toFixed(1)} KB`;
  return '-';
}

function formatMs(ms) {
  const n = Number(ms || 0);
  return n > 0 ? `${n} ms` : '-';
}

function builtAtText(row) {
  return row?.builtAt ? new Date(row.builtAt).toLocaleString() : '未构建';
}

function bundlePercent(row) {
  const cap = Number(row?.bundleMaxSizeKB || row?.config?.bundleMaxSizeKB || 0) * 1024;
  if (cap <= 0) return 0;
  return Math.min(100, Math.round(Number(row.compressedSizeBytes || row.sizeBytes || 0) * 100 / cap));
}

function compressionText(row) {
  const c = row?.compression || {};
  if (c.enabled) return `端侧压缩后 ${c.storedKB} KB / 省 ${c.savingKB} KB`;
  if (!c.compressibleKB) return '图片/字体为主';
  return `文本 ${c.compressibleKB} KB / Brotli ${c.brKB} KB`;
}

function staticCacheText(row) {
  const p = row?.config?.staticCache || {};
  if (p.enabled === false) return '运行时缓存关闭';
  return `运行时: >=${Number(p.minSizeKB || 0)}KB 或 >=${Number(p.minDurationMs || 0)}ms`;
}

function statusType(res) {
  if (res.enabled === false) return 'info';
  if (res.inManifest === false) return 'warning';
  return 'success';
}

function statusText(res) {
  if (res.enabled === false) return '已关闭';
  if (res.inManifest === false) return '未生成';
  return '已入包';
}

async function setResourceEnabled(site, res, enabled) {
  if (!site || !res?.url) return;
  const key = `${site.id}|${res.url}`;
  togglingKey.value = key;
  try {
    const { data } = await api.put(`/api/admin/bundles/${site.id}/resource`, { url: res.url, enabled });
    if (data?.bundle) {
      const idx = bundles.value.findIndex((x) => x.id === site.id);
      if (idx >= 0) bundles.value[idx] = data.bundle;
    } else {
      await load();
    }
    ElMessage.success(enabled ? '已加入离线包' : '已从离线包移除');
  } catch (e) {
    ElMessage.error('更新失败:' + (e.response?.data?.error || e.message));
  } finally {
    togglingKey.value = '';
  }
}

function openImportDialog() {
  if (!selected.value) return;
  importText.value = '';
  importResults.value = [];
  importDialog.value = true;
}

function configMeta(row) {
  return row?.config || row || {};
}

function openConfigDialog() {
  if (!selected.value) return;
  const meta = configMeta(selected.value);
  configText.value = '';
  configFileName.value = meta.configJsonFileName || selected.value.configJsonFileName || `${selected.value.id}.json`;
  configDialog.value = true;
}

function safeJsonFileName(name) {
  const raw = String(name || '').trim() || 'config.json';
  const base = raw.split(/[\\/]/).pop().replace(/[^A-Za-z0-9._-]+/g, '_') || 'config.json';
  return base.toLowerCase().endsWith('.json') ? base : `${base}.json`;
}

async function onConfigFileChange(file) {
  const raw = file?.raw || file;
  if (!raw) return;
  configFileName.value = safeJsonFileName(raw.name || configFileName.value);
  configText.value = await raw.text();
}

async function saveConfigJson() {
  if (!selected.value) return;
  const text = configText.value.trim();
  if (!text) {
    ElMessage.warning('请选择或粘贴 JSON 内容');
    return;
  }
  try {
    JSON.parse(text);
  } catch (e) {
    ElMessage.error('JSON 格式不正确:' + e.message);
    return;
  }
  configSaving.value = true;
  try {
    const { data } = await api.put(`/api/admin/bundles/${selected.value.id}/config-json`, {
      configJson: text,
      fileName: safeJsonFileName(configFileName.value || `${selected.value.id}.json`)
    });
    if (data?.bundle) {
      const idx = bundles.value.findIndex((x) => x.id === selected.value.id);
      if (idx >= 0) bundles.value[idx] = data.bundle;
    } else {
      await load();
    }
    configDialog.value = false;
    ElMessage.success('配置 JSON 已写入离线包');
  } catch (e) {
    const data = e.response?.data;
    ElMessage.error('保存失败:' + (data?.error || e.message));
    if (data?.bundle) {
      const idx = bundles.value.findIndex((x) => x.id === selected.value.id);
      if (idx >= 0) bundles.value[idx] = data.bundle;
    }
  } finally {
    configSaving.value = false;
  }
}

async function importResources() {
  if (!selected.value) return;
  if (!importText.value.trim()) {
    ElMessage.warning('请填写静态资源 URL');
    return;
  }
  importing.value = true;
  try {
    const { data } = await api.post(`/api/admin/bundles/${selected.value.id}/import`, { text: importText.value });
    importResults.value = data.results || [];
    if (data?.bundle) {
      const idx = bundles.value.findIndex((x) => x.id === selected.value.id);
      if (idx >= 0) bundles.value[idx] = data.bundle;
    } else {
      await load();
    }
    const failed = Number(data.failed || 0);
    if (failed > 0) ElMessage.warning(`已导入 ${data.imported || 0} 个,失败 ${failed} 个`);
    else ElMessage.success(`已导入 ${data.imported || 0} 个资源`);
  } catch (e) {
    const data = e.response?.data;
    importResults.value = data?.results || [];
    ElMessage.error('导入失败:' + (data?.error || e.message));
  } finally {
    importing.value = false;
  }
}

function importStatusType(row) {
  return row.ok ? 'success' : 'danger';
}

function importStatusText(row) {
  return row.ok ? '成功' : '失败';
}
</script>

<template>
  <div class="page-card">
    <div class="bundle-head">
      <div>
        <div class="page-title">离线包资源面板</div>
        <div class="muted">按网站查看离线包配置、文件名、大小、耗时和沙箱占用</div>
      </div>
      <div class="head-actions">
        <el-select v-model="groupFilter" size="small" style="width:160px">
          <el-option v-for="g in groupOptions" :key="g.value" :label="g.label" :value="g.value" />
        </el-select>
        <el-tag v-if="autoRunning" type="warning" size="small">检查中</el-tag>
        <el-button :loading="loading" @click="load">刷新</el-button>
        <el-button type="primary" :loading="triggering" @click="runAutoUpdate">检查更新</el-button>
      </div>
    </div>

    <div v-if="autoLog" class="auto-line">
      <span class="muted">上次检查 {{ new Date(autoLog.finishedAt || autoLog.startedAt).toLocaleString() }}</span>
      <el-tag v-for="r in autoLog.results" :key="r.id" :type="r.ok ? (r.action === 'no-change' ? 'info' : 'success') : 'danger'" size="small">
        {{ r.name || r.id }}: {{ r.detail }}
      </el-tag>
    </div>

    <div class="bundle-layout">
      <aside class="site-pane">
        <div class="site-pane-head">
          <div>
            <div class="pane-title">网站</div>
            <div class="site-pane-sub">选择网站维护静态资源</div>
          </div>
          <el-tag size="small" type="info" effect="plain">{{ filteredBundles.length }}</el-tag>
        </div>
        <el-input v-model="siteQuery" :prefix-icon="Search" clearable size="small" class="site-search"
          placeholder="搜索名称 / ID / URL" />
        <el-table :data="filteredBundles" size="small" height="680" highlight-current-row :current-row-key="selectedId" row-key="id" @row-click="selectSite">
          <el-table-column label="名称" min-width="150" show-overflow-tooltip>
            <template #default="{ row }">
              <div class="site-name">{{ row.name || row.id }}</div>
              <div class="site-id">{{ row.id }}</div>
              <el-tooltip :content="groupName(row)" placement="top" :show-after="250">
                <el-tag size="small" :type="(row.scope || row.config?.scope) === 'region' ? 'success' : 'info'">{{ shortGroupName(row) }}</el-tag>
              </el-tooltip>
            </template>
          </el-table-column>
          <el-table-column label="资源" width="86" align="right">
            <template #default="{ row }">
              <div>{{ row.count || 0 }}</div>
              <div class="site-id">{{ formatSize(row.compressedSizeBytes || row.sizeBytes) }}</div>
            </template>
          </el-table-column>
        </el-table>
      </aside>

      <section v-if="selected" class="resource-pane">
        <div class="resource-top">
          <div>
            <div class="resource-title">{{ selected.name || selected.id }}</div>
            <div class="resource-url">{{ selected.url }}</div>
          </div>
          <div class="resource-actions">
            <el-button type="primary" :icon="Upload" @click="openImportDialog">导入资源</el-button>
            <el-button :icon="Upload" @click="openConfigDialog">导入配置 JSON</el-button>
            <el-button link type="primary" @click="copyManifest(selected)">复制 manifest</el-button>
            <el-link type="primary" :href="manifestLink(selected)" target="_blank">打开 manifest</el-link>
          </div>
        </div>

        <div class="metric-row">
          <div class="metric">
            <span>端侧占用</span>
            <b>{{ formatSize(selected.compressedSizeBytes || selected.sizeBytes) }}</b>
          </div>
          <div class="metric">
            <span>原始大小</span>
            <b>{{ formatSize(selected.sizeBytes) }}</b>
          </div>
          <div class="metric">
            <span>容量上限</span>
            <b>{{ selected.bundleMaxSizeKB || selected.config?.bundleMaxSizeKB || 0 }} KB</b>
          </div>
          <div class="metric">
            <span>资源数</span>
            <b>{{ selected.count || 0 }}</b>
          </div>
          <div class="metric">
            <span>更新时间</span>
            <b>{{ builtAtText(selected) }}</b>
          </div>
        </div>

        <div class="capacity-line">
          <el-progress :percentage="bundlePercent(selected)" :stroke-width="8" :show-text="false" />
          <span class="muted">{{ compressionText(selected) }}</span>
        </div>

        <div class="config-strip">
          <el-tag size="small" :type="selected.config?.bundle ? 'success' : 'info'">{{ selected.config?.bundle ? '离线包开启' : '离线包关闭' }}</el-tag>
          <el-tag v-if="configMeta(selected).hasConfigJson" size="small" type="warning">
            JSON {{ configMeta(selected).configJsonFileName || selected.configJsonFileName }} {{ formatSize(configMeta(selected).configJsonBytes || selected.configJsonBytes) }}
          </el-tag>
          <el-tag size="small" type="info">固定 {{ selected.config?.bundleExtraUrls?.length || 0 }}</el-tag>
          <el-tag size="small" type="info">关闭 {{ selected.config?.bundleExcludeUrls?.length || 0 }}</el-tag>
          <span class="muted">{{ staticCacheText(selected) }}</span>
        </div>

        <div class="table-tools">
          <div class="resource-filters">
            <el-radio-group v-model="resourceFilter" size="small">
              <el-radio-button label="all">全部</el-radio-button>
              <el-radio-button label="enabled">已入包</el-radio-button>
              <el-radio-button label="disabled">已关闭</el-radio-button>
              <el-radio-button label="large">大资源</el-radio-button>
              <el-radio-button label="slow">慢资源</el-radio-button>
            </el-radio-group>
            <span class="muted">{{ resources.length }} 条</span>
          </div>
          <el-input v-model="resourceQuery" :prefix-icon="Search" clearable size="small" class="resource-search"
            placeholder="搜索文件名、类型或 URL" />
        </div>

        <el-table :data="resources" border size="small" height="520">
          <el-table-column label="缓存" width="78" align="center">
            <template #default="{ row }">
              <el-switch :model-value="row.enabled !== false"
                :loading="togglingKey === `${selected.id}|${row.url}`"
                @change="(v) => setResourceEnabled(selected, row, v)" />
            </template>
          </el-table-column>
          <el-table-column label="文件名" min-width="260" show-overflow-tooltip>
            <template #default="{ row }">
              <span class="file-name">{{ row.file || '-' }}</span>
              <el-tag v-if="row.encoding" class="encoding-tag" size="small" type="success">{{ row.encoding }}</el-tag>
            </template>
          </el-table-column>
          <el-table-column label="端侧大小" width="110" align="right">
            <template #default="{ row }">{{ formatSize(row.storedSize || row.size) }}</template>
          </el-table-column>
          <el-table-column label="原始大小" width="110" align="right">
            <template #default="{ row }">{{ formatSize(row.size) }}</template>
          </el-table-column>
          <el-table-column label="耗时" width="100" align="right">
            <template #default="{ row }">{{ formatMs(row.costMs) }}</template>
          </el-table-column>
          <el-table-column label="状态" width="90">
            <template #default="{ row }">
              <el-tag size="small" :type="statusType(row)">{{ statusText(row) }}</el-tag>
            </template>
          </el-table-column>
          <el-table-column prop="mime" label="类型" width="150" show-overflow-tooltip />
          <el-table-column prop="url" label="原站 URL" min-width="320" show-overflow-tooltip />
        </el-table>
      </section>
    </div>

    <el-dialog v-model="importDialog" title="导入指定静态资源" width="760px">
      <el-form label-position="top">
        <el-form-item label="目标网站">
          <el-input :model-value="selected ? `${selected.name || selected.id} (${selected.id})` : ''" disabled />
        </el-form-item>
        <el-form-item label="静态资源 URL">
          <el-input v-model="importText" type="textarea" :rows="8"
            placeholder="每行一个完整 URL,例如 https://cdn.example.com/app.bundle.js" />
        </el-form-item>
      </el-form>
      <el-table v-if="importResults.length" :data="importResults" border size="small" max-height="260">
        <el-table-column label="状态" width="76">
          <template #default="{ row }">
            <el-tag size="small" :type="importStatusType(row)">{{ importStatusText(row) }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="url" label="URL" min-width="300" show-overflow-tooltip />
        <el-table-column label="大小" width="96" align="right">
          <template #default="{ row }">{{ row.ok ? formatSize(row.size) : '-' }}</template>
        </el-table-column>
        <el-table-column label="耗时" width="96" align="right">
          <template #default="{ row }">{{ row.ok ? formatMs(row.costMs) : '-' }}</template>
        </el-table-column>
        <el-table-column prop="error" label="错误" min-width="180" show-overflow-tooltip />
      </el-table>
      <template #footer>
        <el-button @click="importDialog = false">关闭</el-button>
        <el-button type="primary" :loading="importing" @click="importResources">导入</el-button>
      </template>
    </el-dialog>

    <el-dialog v-model="configDialog" title="导入配置 JSON" width="760px">
      <el-form label-position="top">
        <el-form-item label="目标网站">
          <el-input :model-value="selected ? `${selected.name || selected.id} (${selected.id})` : ''" disabled />
        </el-form-item>
        <el-form-item label="本地 JSON 文件">
          <div class="config-upload">
            <el-upload action="#" :auto-upload="false" :show-file-list="false"
              accept=".json,application/json" @change="onConfigFileChange">
              <el-button :icon="Upload">选择 JSON 文件</el-button>
            </el-upload>
            <span class="muted">{{ configFileName || '未选择文件' }}</span>
          </div>
        </el-form-item>
        <el-form-item label="JSON 内容">
          <el-input v-model="configText" type="textarea" :rows="10"
            placeholder="选择本地 JSON 文件后会自动填充，也可以直接粘贴完整 JSON" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="configDialog = false">关闭</el-button>
        <el-button type="primary" :loading="configSaving" @click="saveConfigJson">保存到离线包</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.bundle-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
}
.page-title {
  font-size: 20px;
  font-weight: 700;
  margin-bottom: 4px;
}
.head-actions,
.auto-line,
.config-strip,
.table-tools,
.resource-actions,
.config-upload {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.auto-line {
  margin-top: 14px;
  padding: 10px 0;
  border-top: 1px solid #edf0f6;
  border-bottom: 1px solid #edf0f6;
}
.bundle-layout {
  display: grid;
  grid-template-columns: 300px minmax(0, 1fr);
  gap: 16px;
  margin-top: 16px;
}
.site-pane,
.resource-pane {
  border: 1px solid #edf0f6;
  border-radius: 12px;
  background: #fff;
  min-width: 0;
}
.site-pane {
  padding: 12px;
  align-self: start;
}
.resource-pane {
  padding: 16px;
}
.pane-title {
  font-size: 15px;
  font-weight: 700;
  color: #303445;
}
.site-pane-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 10px;
  padding: 2px 4px 0;
}
.site-pane-sub {
  margin-top: 3px;
  color: #959bad;
  font-size: 11px;
}
.site-search {
  margin: 12px 0 10px;
}
.site-name {
  font-weight: 600;
  color: #303133;
}
.site-id,
.resource-url {
  color: #8a90a2;
  font-size: 12px;
}
.site-id {
  margin: 2px 0 5px;
}
.resource-url {
  max-width: 680px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.resource-top {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
  margin-bottom: 14px;
}
.resource-title {
  font-size: 18px;
  font-weight: 700;
  margin-bottom: 4px;
}
.metric-row {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 10px;
  margin-bottom: 12px;
}
.metric {
  border: 1px solid #edf0f6;
  border-radius: 8px;
  padding: 10px 12px;
  min-width: 0;
}
.metric span {
  display: block;
  color: #8a90a2;
  font-size: 12px;
  margin-bottom: 6px;
}
.metric b {
  color: #303133;
  font-size: 15px;
  white-space: nowrap;
}
.capacity-line {
  display: grid;
  grid-template-columns: minmax(160px, 320px) 1fr;
  gap: 12px;
  align-items: center;
  margin-bottom: 12px;
}
.config-strip {
  margin-bottom: 12px;
}
.table-tools {
  justify-content: space-between;
  margin-bottom: 10px;
  padding: 10px 12px;
  border: 1px solid #edf0f6;
  border-radius: 10px;
  background: #fafbfe;
}
.resource-filters {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.resource-search {
  width: 300px;
}
.file-name {
  font-family: ui-monospace, SFMono-Regular, Consolas, 'Liberation Mono', monospace;
  font-size: 12px;
}
.encoding-tag {
  margin-left: 6px;
}
@media (max-width: 980px) {
  .bundle-layout {
    grid-template-columns: 1fr;
  }
  .metric-row {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
  .resource-search {
    width: 100%;
  }
}
</style>
