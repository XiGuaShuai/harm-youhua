<script setup>
import { ref, onMounted, computed } from 'vue';
import { storeToRefs } from 'pinia';
import { ElMessage, ElMessageBox } from 'element-plus';
import { Plus } from '@element-plus/icons-vue';
import api from '../api';
import { useConfigStore } from '../stores/config';

const store = useConfigStore();
const { apps } = storeToRefs(store);

const dialog = ref(false);
const editing = ref(null); // null=新增
const form = ref(emptyForm());
const detecting = ref(false);

// 每个应用的离线包状态(资源数/大小),用于表格"离线包"列一目了然
const bundleMap = ref({});
async function loadBundles() {
  try {
    const { data } = await api.get('/api/admin/bundles');
    const m = {};
    (data || []).forEach((b) => { m[b.id] = b; });
    bundleMap.value = m;
  } catch (e) { /* 忽略 */ }
}
onMounted(loadBundles);

function emptyForm() {
  return { id: '', name: '', url: '', routesText: '/', swrDoc: true, prerender: true, codeCache: true, bundle: true,
    prefetchChunks: true, extraBlockHostsText: '', preconnectHostsText: '', userAgent: '',
    bundleExtraUrlsText: '', bundleExcludeUrlsText: '', bundleMaxSizeKB: 5120,
    staticCacheEnabled: true, staticCacheMinSizeKB: 64, staticCacheMinDurationMs: 800, staticCacheMaxSizeKB: 5120,
    staticCacheIncludeText: '', staticCacheExcludeText: '' };
}
function openAdd() { editing.value = null; form.value = emptyForm(); dialog.value = true; }
function openEdit(row) {
  const staticCache = row.staticCache || {};
  editing.value = row.id;
  form.value = { ...emptyForm(), ...row, routesText: (row.routes || []).join('\n'),
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
    staticCacheExcludeText: (staticCache.exclude || []).join('\n') };
  dialog.value = true;
}

// 一键探测:填了 URL → 自动带出名称/类型/图标/建议加速参数,免手动判断
async function detect() {
  if (!form.value.url) { ElMessage.warning('请先填写 URL'); return; }
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
      // 探测到的跨域CDN/接口域 → 自动填入"预连接域"(管理员可再增删)
      const pc = r.preconnectHosts || data.preconnectHosts || [];
      if (pc.length) form.value.preconnectHostsText = pc.join('\n');
      ElMessage.success(`探测成功:${data.appType} 站,${data.sameOriginCacheable} 个可缓资源,${pc.length} 个CDN域建议预连接,已填入建议参数`);
    }
  } catch (e) {
    ElMessage.error('探测失败:' + (e.response?.data?.error || e.message));
  } finally {
    detecting.value = false;
  }
}

async function submit() {
  if (!form.value.id || !form.value.url) { ElMessage.warning('id 和 url 必填'); return; }
  const item = {
    id: form.value.id, name: form.value.name, url: form.value.url,
    routes: form.value.routesText.split('\n').map((s) => s.trim()).filter(Boolean),
    swrDoc: form.value.swrDoc, prerender: form.value.prerender, codeCache: form.value.codeCache, bundle: form.value.bundle,
    prefetchChunks: form.value.prefetchChunks,
    bundleMaxSizeKB: Number(form.value.bundleMaxSizeKB || 0),
    extraBlockHosts: (form.value.extraBlockHostsText || '').split('\n').map((s) => s.trim()).filter(Boolean),
    preconnectHosts: (form.value.preconnectHostsText || '').split('\n').map((s) => s.trim()).filter(Boolean),
    bundleExtraUrls: (form.value.bundleExtraUrlsText || '').split('\n').map((s) => s.trim()).filter(Boolean),
    bundleExcludeUrls: (form.value.bundleExcludeUrlsText || '').split('\n').map((s) => s.trim()).filter(Boolean),
    userAgent: (form.value.userAgent || '').trim(),  // 自定义UA:空=用默认(不含Mobile则自动追加Mobile);填了=整体替换该站UA
    staticCache: {
      enabled: form.value.staticCacheEnabled,
      minSizeKB: Number(form.value.staticCacheMinSizeKB || 0),
      minDurationMs: Number(form.value.staticCacheMinDurationMs || 0),
      maxSizeKB: Number(form.value.staticCacheMaxSizeKB || 0),
      include: (form.value.staticCacheIncludeText || '').split('\n').map((s) => s.trim()).filter(Boolean),
      exclude: (form.value.staticCacheExcludeText || '').split('\n').map((s) => s.trim()).filter(Boolean)
    }
  };
  const list = [...apps.value];
  const idx = list.findIndex((a) => a.id === editing.value);
  if (idx >= 0) list[idx] = item; else list.push(item);
  apps.value = list;
  const autoBuilding = await store.saveApps();
  dialog.value = false;
  // 后端对"开了离线包且还没建"的站会自动在后台构建,前端不再弹手动构建窗,只提示+稍后刷新状态列
  if (autoBuilding && autoBuilding.includes(item.id)) {
    ElMessage.success(`已保存,正在后台自动构建「${item.name || item.id}」的离线包...`);
    // 离线包构建需时间(几十秒~几分钟),延迟刷新一次离线包状态列让用户看到结果
    setTimeout(() => { loadBundles().catch(() => {}); }, 30000);
  } else {
    ElMessage.success('已保存');
  }
}

async function remove(row) {
  await ElMessageBox.confirm(`删除应用「${row.name || row.id}」?`, '确认', { type: 'warning' });
  apps.value = apps.value.filter((a) => a.id !== row.id);
  await store.saveApps();
  ElMessage.success('已删除');
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
  } catch (e) {
    ElMessage.error('生成失败:' + (e.response?.data?.error || e.message));
  } finally {
    generating.value = '';
  }
}
</script>

<template>
  <div class="page-card">
    <div class="toolbar">
      <el-button type="primary" :icon="Plus" @click="openAdd">新增网页应用</el-button>
      <span class="muted">共 {{ apps.length }} 个应用</span>
    </div>
    <el-table :data="apps" style="margin-top:14px" border>
      <el-table-column prop="id" label="ID" width="120" />
      <el-table-column prop="name" label="名称" width="160" />
      <el-table-column prop="url" label="URL" show-overflow-tooltip />
      <el-table-column label="加速项" width="200">
        <template #default="{ row }">
          <el-tag v-if="row.bundle" size="small" type="success">离线包</el-tag>
          <el-tag v-if="row.prerender" size="small">预渲染</el-tag>
          <el-tag v-if="row.swrDoc" size="small">SWR</el-tag>
          <el-tag v-if="row.codeCache" size="small">字节码</el-tag>
          <el-tag v-if="row.prefetchChunks" size="small" type="info">预取</el-tag>
        </template>
      </el-table-column>
      <el-table-column label="离线包状态" width="150">
        <template #default="{ row }">
          <template v-if="bundleMap[row.id]">
            <el-tag size="small" type="success">已建</el-tag>
            <div class="muted" style="font-size:12px">{{ bundleMap[row.id].count }} 个 / {{ bundleMap[row.id].sizeKB || bundleMap[row.id].kb || 0 }} KB</div>
          </template>
          <el-tag v-else-if="row.bundle" size="small" type="warning">待构建</el-tag>
          <el-tag v-else size="small" type="info">不启用</el-tag>
        </template>
      </el-table-column>
      <el-table-column label="操作" width="500">
        <template #default="{ row }">
          <el-button size="small" :loading="checking === row.id" @click="checkUpdate(row)">检查更新</el-button>
          <el-button size="small" :loading="updating === row.id" @click="updateCache(row)">增量更新</el-button>
          <el-button size="small" :loading="building === row.id" @click="buildCache(row)">强制重建</el-button>
          <el-button size="small" :loading="generating === row.id" @click="generateManifest(row)">生成清单</el-button>
          <el-button size="small" @click="openEdit(row)">编辑</el-button>
          <el-button size="small" type="danger" @click="remove(row)">删除</el-button>
        </template>
      </el-table-column>
    </el-table>

    <el-dialog v-model="dialog" :title="editing ? '编辑应用' : '新增应用'" width="520px">
      <el-form label-width="92px">
        <el-form-item label="ID">
          <el-input v-model="form.id" :disabled="!!editing" placeholder="唯一标识,如 beacukai" />
        </el-form-item>
        <el-form-item label="URL">
          <div style="display:flex; gap:8px; width:100%">
            <el-input v-model="form.url" placeholder="https://..." />
            <el-button :loading="detecting" @click="detect">一键探测</el-button>
          </div>
        </el-form-item>
        <el-form-item label="名称"><el-input v-model="form.name" placeholder="探测可自动填入" /></el-form-item>
        <el-form-item label="路由">
          <el-input v-model="form.routesText" type="textarea" :rows="3"
            placeholder="每行一个二级页路径(如 /shop/、/taste/),用于预取该页资源与构建缓存" />
        </el-form-item>
        <el-form-item label="加速项">
          <el-checkbox v-model="form.bundle">离线包</el-checkbox>
          <el-checkbox v-model="form.prerender">离屏预渲染</el-checkbox>
          <el-checkbox v-model="form.swrDoc">主文档 SWR</el-checkbox>
          <el-checkbox v-model="form.codeCache">字节码缓存</el-checkbox>
          <el-checkbox v-model="form.prefetchChunks">chunk 预取</el-checkbox>
        </el-form-item>
        <el-form-item label="额外黑名单">
          <el-input v-model="form.extraBlockHostsText" type="textarea" :rows="2"
            placeholder="只对本应用生效的额外屏蔽域(每行一个),叠加在全局黑名单之上。如 Booking 的遥测域" />
        </el-form-item>
        <el-form-item label="预连接域">
          <el-input v-model="form.preconnectHostsText" type="textarea" :rows="2"
            placeholder="该站资源/接口所在的跨域CDN域(每行一个),开机提前做DNS+TLS握手,点进去时资源直连不等握手。如视频/JS渲染站(主文档空、资源在跨域CDN)填其CDN域,能压短白屏。例:s1.hdslb.com" />
        </el-form-item>
        <el-form-item label="固定资源">
          <el-input v-model="form.bundleExtraUrlsText" type="textarea" :rows="3"
            placeholder="每行一个确认固定的静态资源 URL。用于把跨域大背景图/主图纳入离线包;小图和频繁变化的运营图不要放。" />
        </el-form-item>
        <el-form-item label="排除资源">
          <el-input v-model="form.bundleExcludeUrlsText" type="textarea" :rows="3"
            placeholder="每行一个不进离线包的静态资源 URL。也可以在「离线包」页明细里直接关闭某个资源。" />
        </el-form-item>
        <el-form-item label="离线包上限">
          <el-input-number v-model="form.bundleMaxSizeKB" :min="0" :max="204800" :step="512" controls-position="right" />
          <div class="muted" style="font-size:12px; margin-top:4px">
            单个应用离线包资源总量上限,单位 KB。0 表示不限制;建议按 200MB 沙箱预留空间,每站单独控制。
          </div>
        </el-form-item>
        <el-form-item label="静态缓存">
          <el-switch v-model="form.staticCacheEnabled" active-text="启用" inactive-text="关闭" />
          <div class="muted" style="font-size:12px; margin-top:4px">
            控制运行时缓存和离线包构建时哪些静态资源进沙箱。建议只保留大资源/慢资源,避免 200MB 沙箱被小碎片占满。
          </div>
        </el-form-item>
        <el-form-item label="缓存阈值">
          <div style="display:grid; grid-template-columns:1fr 1fr 1fr; gap:8px; width:100%">
            <el-input-number v-model="form.staticCacheMinSizeKB" :min="0" :max="20480" :step="16" controls-position="right" />
            <el-input-number v-model="form.staticCacheMinDurationMs" :min="0" :max="30000" :step="100" controls-position="right" />
            <el-input-number v-model="form.staticCacheMaxSizeKB" :min="0" :max="51200" :step="256" controls-position="right" />
          </div>
          <div class="muted" style="font-size:12px">依次为:最小体积KB / 最小耗时ms / 单资源最大KB。命中体积或耗时任一条件即缓存。</div>
        </el-form-item>
        <el-form-item label="强制缓存">
          <el-input v-model="form.staticCacheIncludeText" type="textarea" :rows="2"
            placeholder="每行一个 URL 子串或 * 通配。命中即缓存,不受阈值限制。如 /files/art/js/bundle.min.js" />
        </el-form-item>
        <el-form-item label="禁止缓存">
          <el-input v-model="form.staticCacheExcludeText" type="textarea" :rows="2"
            placeholder="每行一个 URL 子串或 * 通配。命中即不缓存,优先级最高。如 analytics、/ga.js、*.map" />
        </el-form-item>
        <el-form-item label="自定义UA">
          <el-input v-model="form.userAgent" type="textarea" :rows="2"
            placeholder="留空=用默认UA(不含Mobile会自动追加,多数站返回移动版)。某些站按UA分手机/桌面分支,需指定时填整条UA覆盖。例(桌面):Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="dialog = false">取消</el-button>
        <el-button type="primary" @click="submit">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.toolbar { display: flex; align-items: center; justify-content: space-between; }
</style>
