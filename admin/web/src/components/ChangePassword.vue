<script setup>
import { ref } from 'vue';
import { ElMessage } from 'element-plus';
import { useAuthStore } from '../stores/auth';

const auth = useAuthStore();
const visible = defineModel({ default: false });

const form = ref({ oldPassword: '', newPassword: '', confirm: '' });
const loading = ref(false);

function reset() { form.value = { oldPassword: '', newPassword: '', confirm: '' }; }

async function submit() {
  if (!form.value.oldPassword || !form.value.newPassword) { ElMessage.warning('请填写完整'); return; }
  if (form.value.newPassword.length < 6) { ElMessage.warning('新密码至少 6 位'); return; }
  if (form.value.newPassword !== form.value.confirm) { ElMessage.warning('两次输入的新密码不一致'); return; }
  loading.value = true;
  try {
    await auth.changePassword(form.value.oldPassword, form.value.newPassword);
    ElMessage.success('密码已修改');
    visible.value = false;
    reset();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '修改失败');
  } finally {
    loading.value = false;
  }
}
</script>

<template>
  <el-dialog v-model="visible" title="修改密码" width="420px" @closed="reset">
    <el-form label-width="80px">
      <el-form-item label="原密码">
        <el-input v-model="form.oldPassword" type="password" show-password placeholder="当前密码" />
      </el-form-item>
      <el-form-item label="新密码">
        <el-input v-model="form.newPassword" type="password" show-password placeholder="至少 6 位" />
      </el-form-item>
      <el-form-item label="确认">
        <el-input v-model="form.confirm" type="password" show-password placeholder="再输一次新密码"
          @keyup.enter="submit" />
      </el-form-item>
    </el-form>
    <template #footer>
      <el-button @click="visible = false">取消</el-button>
      <el-button type="primary" :loading="loading" @click="submit">确定</el-button>
    </template>
  </el-dialog>
</template>
