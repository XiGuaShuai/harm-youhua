<script setup>
import { ref, onMounted } from 'vue';
import { ElMessage } from 'element-plus';
import api from '../api';

const bundles = ref([]);
const loading = ref(false);

// 自动更新状态
const autoLog = ref(null);
const autoRunning = ref(false);
const triggering = ref(false);

async function load() {
  loading.value = true;
  try {
    const { data } = await api.get('/api/admin/bundles');
    bundles.value = data;
  } finally {
    loading.value = false;
  }
  loadAutoLog();
}
onMounted(load);

async function loadAutoLog() {
  try {
    const { data } = await api.get('/api/admin/auto-update/log');
    autoLog.value = data.log;
    autoRunning.value = data.running;
  } catch (e) { /* 忽略 */ }
}

// 立即检查全部站的更新(手动触发自动更新)
async function runAutoUpdate() {
  triggering.value = true;
  try {
    await api.post('/api/admin/auto-update/run');
    ElMessage.success('已触发,后台检查中。稍等几秒点"刷新"看结果');
    autoRunning.value = true;
    // 5秒后自动刷新一次结果
    setTimeout(() => { loadAutoLog(); load(); }, 6000);
  } catch (e) {
    ElMessage.error('触发失败:' + (e.response?.data?.error || e.message));
  } finally {
    triggering.value = false;
  }
}

function manifestLink(row) {
  return location.origin + row.manifestUrl; // 开发下经 vite 代理;生产填服务器地址
}
function copy(row) {
  navigator.clipboard.writeText(manifestLink(row));
  ElMessage.success('已复制 manifest 地址');
}
</script>

<template>
  <div class="page-card">
    <el-alert type="info" :closable="false" show-icon style="margin-bottom:12px">
      「构建缓存」会访问目标站并刷新服务器缓存文件;「生成清单」只扫描已有缓存文件生成 manifest。
      鸿蒙 App 用 manifest 从你的服务器拉取缓存文件,再注入到端侧沙箱缓存。
    </el-alert>
    <!-- 自动更新:每天自动检查所有站源站更新并重建离线包 -->
    <el-card shadow="never" style="margin-bottom:12px; border:1px solid #ebeef5">
      <div style="display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:8px">
        <div>
          <b>🔄 离线包自动更新</b>
          <span style="color:#888; margin-left:8px">每天自动检查所有站源站更新,有更新自动重建,失败自动重试</span>
        </div>
        <div>
          <el-tag v-if="autoRunning" type="warning" size="small">检查中…</el-tag>
          <el-button type="primary" :loading="triggering" @click="runAutoUpdate" size="small">立即检查全部更新</el-button>
        </div>
      </div>
      <div v-if="autoLog" style="margin-top:10px; font-size:13px; color:#666">
        上次检查:{{ new Date(autoLog.finishedAt || autoLog.startedAt).toLocaleString() }}({{ autoLog.trigger === 'manual' ? '手动' : autoLog.trigger === 'startup' ? '启动' : '定时' }})
        <div style="margin-top:6px">
          <el-tag v-for="r in autoLog.results" :key="r.id" :type="r.ok ? (r.action==='no-change'?'info':'success') : 'danger'" size="small" style="margin:2px 6px 2px 0">
            {{ r.name || r.id }}: {{ r.detail }}
          </el-tag>
        </div>
      </div>
    </el-card>

    <el-button :loading="loading" @click="load">刷新</el-button>
    <el-table :data="bundles" border style="margin-top:12px">
      <el-table-column prop="id" label="应用 ID" width="140" />
      <el-table-column prop="count" label="资源数" width="100" />
      <el-table-column prop="sizeKB" label="大小 (KB)" width="120" />
      <el-table-column label="清单时间" width="200">
        <template #default="{ row }">{{ new Date(row.builtAt).toLocaleString() }}</template>
      </el-table-column>
      <el-table-column label="manifest 地址">
        <template #default="{ row }">
          <el-link type="primary" :href="manifestLink(row)" target="_blank">{{ row.manifestUrl }}</el-link>
          <el-button link type="primary" @click="copy(row)">复制</el-button>
        </template>
      </el-table-column>
    </el-table>
  </div>
</template>
