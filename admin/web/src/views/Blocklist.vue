<script setup>
import { ref, watch } from 'vue';
import { storeToRefs } from 'pinia';
import { ElMessage } from 'element-plus';
import { useConfigStore } from '../stores/config';

const store = useConfigStore();
const { blockHosts } = storeToRefs(store);

const text = ref('');
watch(blockHosts, (v) => { text.value = (v || []).join('\n'); }, { immediate: true });

async function save() {
  blockHosts.value = text.value.split('\n').map((s) => s.trim()).filter(Boolean);
  await store.saveBlockHosts();
  ElMessage.success(`已保存 ${blockHosts.value.length} 条`);
}
</script>

<template>
  <div class="page-card">
    <el-alert type="info" :closable="false" show-icon style="margin-bottom:12px">
      命中这些域名/路径的请求,App 端会立刻空响应(秒拒),不再傻等被墙的第三方超时。
      只放「屏蔽后不影响功能」的:统计 / 广告 / Google 字体 / 社交追踪。
      <b>不要放 recaptcha / maps / 支付</b> 等功能性第三方。每行一条(子串匹配)。
    </el-alert>
    <el-input v-model="text" type="textarea" :rows="18" style="font-family:monospace" />
    <el-button type="primary" style="margin-top:12px" @click="save">保存黑名单</el-button>
  </div>
</template>
