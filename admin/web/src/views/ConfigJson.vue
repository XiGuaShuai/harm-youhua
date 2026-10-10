<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { storeToRefs } from 'pinia';
import { ElMessage, ElMessageBox } from 'element-plus';
import { Refresh, RefreshRight, Search } from '@element-plus/icons-vue';
import api from '../api';
import { useConfigStore } from '../stores/config';
import {
  CONFIG_ENVIRONMENT_OPTIONS,
  adminShowsAll,
  adminViewLocked,
  defaultViewEnvironment,
  environmentLabel
} from '../adminPath';
import { displayRegionName, selectRegionIdsForEnvironment } from '../regionCatalog';

const route = useRoute();
const store = useConfigStore();
const { apps, loading } = storeToRefs(store);

const pathLocked = adminViewLocked();
const pathShowsAll = adminShowsAll();
const viewEnvironment = ref(
  pathLocked
    ? defaultViewEnvironment()
    : (['test', 'pre', 'prod'].includes(String(route.query.environment || ''))
      ? String(route.query.environment)
      : defaultViewEnvironment())
);
const siteQuery = ref('');
const onlyReady = ref(true);
const syncingId = ref('');
const syncingAll = ref(false);
const lastResults = ref([]);
const health = ref(null);

const environmentName = computed(() => environmentLabel(viewEnvironment.value));

function hasConfigSyncSource(sync) {
  return !!String(sync?.loginUrl || '').trim() && !!String(sync?.configUrl || '').trim();
}

function envMetaOf(row, environment = viewEnvironment.value) {
  return row?.configJsonEnvironments?.[environment] || {};
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

function viewRegionIdsOf(row) {
  if (pathShowsAll) return regionIdsOf(row);
  return selectRegionIdsForEnvironment(regionIdsOf(row), viewEnvironment.value, {
    appName: row?.name,
    regionNames: regionNamesOf(row)
  });
}

function regionLabel(row) {
  const ids = viewRegionIdsOf(row);
  if (!ids.length) return row?.scope === 'top' ? 'TOP 常驻（全地区）' : '未配置地区';
  const names = regionNamesOf(row);
  return ids
    .map((id) => displayRegionName(id, names[id] || row?.regionName || '', { environment: viewEnvironment.value }))
    .join('、');
}

function jsonBytes(row) {
  const text = String(envMetaOf(row).configJson || '');
  if (!text) return 0;
  try {
    return new TextEncoder().encode(text).length;
  } catch {
    return text.length;
  }
}

function formatBytes(n) {
  const size = Number(n || 0);
  if (size >= 1024 * 1024) return `${(size / 1024 / 1024).toFixed(2)} MB`;
  if (size >= 1024) return `${(size / 1024).toFixed(1)} KB`;
  if (size > 0) return `${size} B`;
  return '-';
}

function formatTime(value) {
  if (!value) return '从未同步';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toLocaleString();
}

const rows = computed(() => {
  const q = siteQuery.value.trim().toLowerCase();
  return (apps.value || [])
    .map((app) => {
      const meta = envMetaOf(app);
      const sync = meta.configJsonSync || {};
      const ready = hasConfigSyncSource(sync);
      const regionIds = viewRegionIdsOf(app);
      return {
        ...app,
        _ready: ready,
        _syncedAt: meta.configJsonSyncedAt || '',
        _jsonBytes: jsonBytes(app),
        _regionIds: regionIds,
        _regionLabel: regionLabel(app),
        _syncEnabled: sync.enabled === true || ready
      };
    })
    .filter((row) => {
      if (onlyReady.value && !row._ready) return false;
      if (!q) return true;
      return [row.id, row.name, row.url, row._regionLabel]
        .some((value) => String(value || '').toLowerCase().includes(q));
    })
    .sort((a, b) => String(a.name || a.id).localeCompare(String(b.name || b.id), 'zh'));
});

async function loadHealth() {
  try {
    const { data } = await api.get('/api/admin/config-json-sync/status');
    health.value = data;
  } catch {
    health.value = null;
  }
}

async function refresh() {
  await Promise.all([store.load(), loadHealth()]);
}

function summarizeResults(results, appName = '') {
  const list = Array.isArray(results) ? results : [];
  const failed = list.filter((item) => item.ok === false);
  const changed = list.filter((item) => item.changed === true);
  const skipped = list.filter((item) => item.ok !== false && String(item.detail || '').startsWith('跳过'));
  const prefix = appName ? `「${appName}」` : '';
  if (failed.length > 0) {
    ElMessage.error(
      `${prefix}${environmentName.value}更新失败：` +
      failed.map((item) => `${item.environmentName || item.environment}:${item.detail}`).join('；')
    );
    return;
  }
  if (changed.length > 0) {
    ElMessage.success(`${prefix}${environmentName.value} configJson 已更新（覆盖该应用全部地区）`);
    return;
  }
  if (skipped.length === list.length && list.length > 0) {
    ElMessage.warning(
      `${prefix}${environmentName.value}未拉取到 JSON：` +
      skipped.map((item) => item.detail).join('；')
    );
    return;
  }
  ElMessage.success(`${prefix}${environmentName.value}已检查，内容无变化（覆盖该应用全部地区）`);
}

async function syncOne(row) {
  if (!row?._ready) {
    ElMessage.warning(`「${row.name || row.id}」${environmentName.value}未配置同步地址`);
    return;
  }
  syncingId.value = row.id;
  lastResults.value = [];
  try {
    const { data } = await api.post('/api/admin/config-json-sync/run', {
      appId: row.id,
      environment: viewEnvironment.value
    });
    if (data?.log?.skipped) {
      ElMessage.warning(data.log.reason || '后台正在同步，请稍后再点');
      return;
    }
    const results = (data?.log?.results || []).filter((item) => item.environment === viewEnvironment.value);
    lastResults.value = results.map((item) => ({
      ...item,
      name: item.name || row.name || row.id,
      regionsCount: item.regionsCount ?? row._regionIds.length
    }));
    summarizeResults(results, row.name || row.id);
    await refresh();
  } catch (e) {
    ElMessage.error('更新失败:' + (e.response?.data?.error || e.message));
  } finally {
    syncingId.value = '';
  }
}

async function syncCurrentEnvironment() {
  const targets = rows.value.filter((row) => row._ready);
  if (!targets.length) {
    ElMessage.warning(`${environmentName.value}没有可同步的应用`);
    return;
  }
  await ElMessageBox.confirm(
    `将从运营后台重新拉取 ${environmentName.value}环境 ${targets.length} 个应用的 configJson。\n每个应用只写回一份 JSON，会覆盖该应用绑定的全部地区。`,
    `更新${environmentName.value}环境全部 JSON`,
    { type: 'warning', confirmButtonText: '开始更新', cancelButtonText: '取消' }
  );
  syncingAll.value = true;
  lastResults.value = [];
  try {
    const { data } = await api.post('/api/admin/config-json-sync/run', {
      environment: viewEnvironment.value
    });
    if (data?.log?.skipped) {
      ElMessage.warning(data.log.reason || '后台正在同步，请稍后再点');
      return;
    }
    const results = (data?.log?.results || []).filter((item) => item.environment === viewEnvironment.value);
    lastResults.value = results;
    summarizeResults(results);
    await refresh();
  } catch (e) {
    if (e !== 'cancel' && e !== 'close') {
      ElMessage.error('批量更新失败:' + (e.response?.data?.error || e.message));
    }
  } finally {
    syncingAll.value = false;
  }
}

onMounted(() => {
  if (!apps.value.length) store.load();
  loadHealth();
});

watch(viewEnvironment, () => {
  lastResults.value = [];
});
</script>

<template>
  <div class="page-card">
    <div class="page-head">
      <div>
        <div class="page-title">更新 configJson</div>
        <div class="muted">
          按应用从运营后台拉取 JSON，并写回当前环境。一个应用只存一份 JSON，会覆盖它绑定的全部地区；测试 / 预发 / 正式仍然分开。
        </div>
      </div>
      <div class="head-actions">
        <el-tag v-if="pathLocked" type="warning" effect="plain">{{ environmentName }}环境</el-tag>
        <el-radio-group v-else v-model="viewEnvironment" size="small">
          <el-radio-button v-for="option in CONFIG_ENVIRONMENT_OPTIONS" :key="option.id" :label="option.id">
            {{ option.name }}
          </el-radio-button>
        </el-radio-group>
        <el-button :icon="Refresh" :loading="loading" @click="refresh">刷新</el-button>
        <el-button
          type="primary"
          :icon="RefreshRight"
          :loading="syncingAll"
          :disabled="!!syncingId"
          @click="syncCurrentEnvironment"
        >
          更新当前环境全部
        </el-button>
      </div>
    </div>

    <div class="toolbar">
      <el-input
        v-model="siteQuery"
        clearable
        size="small"
        :prefix-icon="Search"
        placeholder="搜索应用名 / ID / 地区"
        style="width: 260px"
      />
      <el-checkbox v-model="onlyReady">只看已配置同步源</el-checkbox>
      <el-tag v-if="health?.healthy === false" type="danger" effect="plain">
        {{ health.message || '定时同步异常' }}
      </el-tag>
      <el-tag v-else-if="health?.healthy === true" type="success" effect="plain">
        {{ health.message || '定时同步正常' }}
      </el-tag>
      <a class="status-link" href="/config-json-sync.html" target="_blank" rel="noreferrer">查看同步状态页</a>
    </div>

    <el-table :data="rows" v-loading="loading || syncingAll" size="small" row-key="id">
      <el-table-column label="应用" min-width="180">
        <template #default="{ row }">
          <div class="app-name">{{ row.name || row.id }}</div>
          <div class="muted mono">{{ row.id }}</div>
        </template>
      </el-table-column>
      <el-table-column label="覆盖地区" min-width="260">
        <template #default="{ row }">
          <div>{{ row._regionIds.length }} 个地区</div>
          <div class="muted region-text" :title="row._regionLabel">{{ row._regionLabel }}</div>
        </template>
      </el-table-column>
      <el-table-column label="当前 JSON" width="120">
        <template #default="{ row }">
          {{ formatBytes(row._jsonBytes) }}
        </template>
      </el-table-column>
      <el-table-column label="上次同步" min-width="170">
        <template #default="{ row }">
          {{ formatTime(row._syncedAt) }}
        </template>
      </el-table-column>
      <el-table-column label="同步源" width="100">
        <template #default="{ row }">
          <el-tag v-if="row._ready" size="small" type="success" effect="plain">已配置</el-tag>
          <el-tag v-else size="small" type="info" effect="plain">未配置</el-tag>
        </template>
      </el-table-column>
      <el-table-column label="操作" width="160" fixed="right">
        <template #default="{ row }">
          <el-button
            size="small"
            type="primary"
            plain
            :icon="RefreshRight"
            :loading="syncingId === row.id"
            :disabled="!row._ready || syncingAll || (!!syncingId && syncingId !== row.id)"
            @click="syncOne(row)"
          >
            更新此应用
          </el-button>
        </template>
      </el-table-column>
      <template #empty>
        {{ onlyReady ? `${environmentName}环境暂无已配置同步源的应用` : '暂无应用' }}
      </template>
    </el-table>

    <el-card v-if="lastResults.length" class="result-card" shadow="never">
      <template #header>
        <div class="card-head">
          <span>最近一次操作结果 · {{ environmentName }}</span>
        </div>
      </template>
      <el-table :data="lastResults" size="small">
        <el-table-column prop="name" label="应用" min-width="140">
          <template #default="{ row }">{{ row.name || row.id }}</template>
        </el-table-column>
        <el-table-column label="地区数" width="90">
          <template #default="{ row }">{{ row.regionsCount ?? '-' }}</template>
        </el-table-column>
        <el-table-column label="结果" min-width="220">
          <template #default="{ row }">
            <el-tag
              size="small"
              :type="row.ok === false ? 'danger' : (row.changed ? 'success' : 'info')"
              effect="plain"
            >
              {{ row.ok === false ? '失败' : (row.changed ? '已更新' : '无变化') }}
            </el-tag>
            <span class="muted result-detail">{{ row.detail }}</span>
          </template>
        </el-table-column>
        <el-table-column label="体积" width="110">
          <template #default="{ row }">{{ formatBytes(row.bytes) }}</template>
        </el-table-column>
      </el-table>
    </el-card>
  </div>
</template>

<style scoped>
.page-card {
  background: #fff;
  border-radius: 14px;
  padding: 18px 18px 8px;
  box-shadow: 0 1px 4px rgba(31, 36, 51, .04);
}
.page-head {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  align-items: flex-start;
  margin-bottom: 14px;
}
.page-title {
  font-size: 18px;
  font-weight: 700;
  color: #1f2433;
}
.muted { color: #9aa0b0; font-size: 12px; line-height: 1.5; }
.mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.head-actions, .toolbar, .card-head {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.toolbar {
  margin-bottom: 12px;
}
.app-name { font-weight: 600; color: #1f2433; }
.region-text {
  max-width: 420px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.status-link {
  color: #4f5bd5;
  font-size: 12px;
  text-decoration: none;
}
.status-link:hover { text-decoration: underline; }
.result-card {
  margin-top: 16px;
  border: 1px solid #edf0f5;
}
.result-detail { margin-left: 8px; }
</style>
