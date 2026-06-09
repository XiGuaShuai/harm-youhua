<script setup>
import { storeToRefs } from 'pinia';
import { ElMessage } from 'element-plus';
import { useConfigStore } from '../stores/config';

const store = useConfigStore();
const { settings } = storeToRefs(store);

async function save() {
  await store.saveSettings();
  ElMessage.success('已保存');
}
</script>

<template>
  <div class="page-card" style="max-width:560px">
    <el-form label-width="180px">
      <el-form-item label="运行时缓存上限 (MB)">
        <el-input-number v-model="settings.diskCapMB" :min="8" :max="512" :step="8" />
        <div class="hint">沙箱缓存超过此值按 LRU 淘汰(对应 DISK_CAP_BYTES)。</div>
      </el-form-item>
      <el-form-item label="主文档版本校验节流 (秒)">
        <el-input-number v-model="settings.docCheckSec" :min="0" :max="3600" :step="10" />
        <div class="hint">多久才重拉一次首页 HTML 比对版本(对应 DOC_CHECK_MS)。</div>
      </el-form-item>
      <el-form-item label="离线包下载并发">
        <el-input-number v-model="settings.bundleConcurrency" :min="1" :max="8" :step="1" />
        <div class="hint">App 从后台拉取离线包时的后台下载并发;过高会抢占首屏网络。</div>
      </el-form-item>
      <el-form-item label="全站 chunk 预取">
        <el-switch v-model="settings.prefetchChunks" />
        <div class="hint">页面加载完后台预取该站全部按需 chunk(Next.js 系站点有效;非 Next 站自动无操作)。</div>
      </el-form-item>
      <el-form-item label="JS 字节码缓存">
        <el-switch v-model="settings.bytecodeCache" />
        <div class="hint">元服务环境已禁用字节码注入,该字段仅保留兼容。</div>
      </el-form-item>
      <el-form-item>
        <el-button type="primary" @click="save">保存设置</el-button>
      </el-form-item>
    </el-form>
    <el-alert type="warning" :closable="false" show-icon>
      这些设置由鸿蒙 App 开机从 <code>/api/config</code> 拉取后生效(需 App 端接入远程配置,见 README)。
    </el-alert>
  </div>
</template>

<style scoped>
.hint { color: #999; font-size: 12px; line-height: 1.5; }
</style>
