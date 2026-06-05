<script setup>
import { ref } from 'vue';
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

function emptyForm() {
  return { id: '', name: '', url: '', routesText: '/', swrDoc: true, prerender: true, codeCache: true, bundle: true };
}
function openAdd() { editing.value = null; form.value = emptyForm(); dialog.value = true; }
function openEdit(row) {
  editing.value = row.id;
  form.value = { ...row, routesText: (row.routes || []).join('\n') };
  dialog.value = true;
}

async function submit() {
  if (!form.value.id || !form.value.url) { ElMessage.warning('id 和 url 必填'); return; }
  const item = {
    id: form.value.id, name: form.value.name, url: form.value.url,
    routes: form.value.routesText.split('\n').map((s) => s.trim()).filter(Boolean),
    swrDoc: form.value.swrDoc, prerender: form.value.prerender, codeCache: form.value.codeCache, bundle: form.value.bundle
  };
  const list = [...apps.value];
  const idx = list.findIndex((a) => a.id === editing.value);
  if (idx >= 0) list[idx] = item; else list.push(item);
  apps.value = list;
  await store.saveApps();
  dialog.value = false;
  ElMessage.success('已保存');
}

async function remove(row) {
  await ElMessageBox.confirm(`删除应用「${row.name || row.id}」?`, '确认', { type: 'warning' });
  apps.value = apps.value.filter((a) => a.id !== row.id);
  await store.saveApps();
  ElMessage.success('已删除');
}

const building = ref('');
async function build(row) {
  building.value = row.id;
  try {
    const { data } = await api.post(`/api/admin/bundles/${row.id}/build`);
    ElMessage.success(`已打包 ${data.count} 个资源`);
  } catch (e) {
    ElMessage.error('打包失败:' + (e.response?.data?.error || e.message));
  } finally {
    building.value = '';
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
      <el-table-column label="加速项" width="220">
        <template #default="{ row }">
          <el-tag v-if="row.bundle" size="small" type="success">内置包</el-tag>
          <el-tag v-if="row.prerender" size="small">预渲染</el-tag>
          <el-tag v-if="row.swrDoc" size="small">SWR</el-tag>
          <el-tag v-if="row.codeCache" size="small">字节码</el-tag>
        </template>
      </el-table-column>
      <el-table-column label="操作" width="240">
        <template #default="{ row }">
          <el-button size="small" :loading="building === row.id" @click="build(row)">服务端打包</el-button>
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
        <el-form-item label="名称"><el-input v-model="form.name" /></el-form-item>
        <el-form-item label="URL"><el-input v-model="form.url" placeholder="https://..." /></el-form-item>
        <el-form-item label="路由">
          <el-input v-model="form.routesText" type="textarea" :rows="4"
            placeholder="每行一个,用于离线打包(/ 为首页)" />
        </el-form-item>
        <el-form-item label="加速项">
          <el-checkbox v-model="form.bundle">内置离线包</el-checkbox>
          <el-checkbox v-model="form.prerender">离屏预渲染</el-checkbox>
          <el-checkbox v-model="form.swrDoc">主文档 SWR</el-checkbox>
          <el-checkbox v-model="form.codeCache">字节码缓存</el-checkbox>
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
