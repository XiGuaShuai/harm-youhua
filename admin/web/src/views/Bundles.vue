<script setup>
import { ref, onMounted } from 'vue';
import { ElMessage } from 'element-plus';
import api from '../api';

const bundles = ref([]);
const loading = ref(false);

async function load() {
  loading.value = true;
  try {
    const { data } = await api.get('/api/admin/bundles');
    bundles.value = data;
  } finally {
    loading.value = false;
  }
}
onMounted(load);

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
      在「应用管理」里点 <b>服务端打包</b> 后,离线包出现在这里,托管于 <code>/bundles/&lt;id&gt;/</code>。
      鸿蒙 App 用这个 manifest 地址从你的服务器拉取离线包(国内快),替代/补充打进 HAP 的内置包。
    </el-alert>
    <el-button :loading="loading" @click="load">刷新</el-button>
    <el-table :data="bundles" border style="margin-top:12px">
      <el-table-column prop="id" label="应用 ID" width="140" />
      <el-table-column prop="count" label="资源数" width="100" />
      <el-table-column prop="sizeKB" label="大小 (KB)" width="120" />
      <el-table-column label="打包时间" width="200">
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
