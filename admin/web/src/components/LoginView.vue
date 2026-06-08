<script setup>
import { ref } from 'vue';
import { ElMessage } from 'element-plus';
import { User, Lock } from '@element-plus/icons-vue';
import { useAuthStore } from '../stores/auth';

const auth = useAuthStore();
const emit = defineEmits(['done']);

const form = ref({ username: 'admin', password: '' });
const loading = ref(false);

async function submit() {
  if (!form.value.username || !form.value.password) {
    ElMessage.warning('请输入账号和密码');
    return;
  }
  loading.value = true;
  try {
    await auth.login(form.value.username, form.value.password);
    ElMessage.success('登录成功');
    emit('done');
  } catch (e) {
    const msg = e.response?.data?.error || (e.response ? '账号或密码不正确' : '连不上后端,请先启动 server');
    ElMessage.error(msg);
  } finally {
    loading.value = false;
  }
}
</script>

<template>
  <div class="login-page">
    <!-- 左侧品牌 -->
    <div class="brand">
      <div class="brand-inner">
        <div class="logo">
          <svg viewBox="0 0 24 24" width="34" height="34" fill="#fff"><path d="M13 2 3 14h7l-1 8 11-13h-8z"/></svg>
        </div>
        <h1>网页加速 · 控制台</h1>
        <p>鸿蒙网页应用的远程配置与离线包分发中心</p>
        <ul class="features">
          <li>应用、黑名单、全局设置一处下发</li>
          <li>服务端缓存清单一键生成</li>
          <li>改配置即生效,App 无需重新发版</li>
        </ul>
      </div>
      <div class="copyright">youhua-admin · {{ new Date().getFullYear() }}</div>
    </div>

    <!-- 右侧登录表单 -->
    <div class="form-side">
      <div class="form-box">
        <h2>欢迎回来 👋</h2>
        <p class="sub">登录后台管理系统</p>
        <el-form @submit.prevent="submit">
          <el-form-item>
            <el-input v-model="form.username" size="large" placeholder="账号" :prefix-icon="User" clearable />
          </el-form-item>
          <el-form-item>
            <el-input v-model="form.password" size="large" placeholder="密码" :prefix-icon="Lock"
              type="password" show-password @keyup.enter="submit" />
          </el-form-item>
          <el-button type="primary" size="large" class="login-btn" :loading="loading" @click="submit">
            登 录
          </el-button>
        </el-form>
        <div class="tip">默认账号 <code>admin</code> / 密码 <code>admin123</code>,登录后请尽快修改</div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.login-page {
  height: 100vh;
  display: flex;
  background: var(--app-bg);
}

/* 左侧品牌区 */
.brand {
  flex: 1.1;
  background: var(--brand-grad);
  color: #fff;
  padding: 56px 60px;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  position: relative;
  overflow: hidden;
}
.brand::after {
  content: '';
  position: absolute;
  right: -120px;
  bottom: -120px;
  width: 360px;
  height: 360px;
  border-radius: 50%;
  background: rgba(255, 255, 255, .08);
}
.brand-inner { max-width: 420px; }
.logo {
  width: 64px; height: 64px; border-radius: 16px;
  background: rgba(255, 255, 255, .18);
  display: flex; align-items: center; justify-content: center;
  margin-bottom: 28px;
}
.brand h1 { font-size: 30px; margin: 0 0 12px; line-height: 1.3; }
.brand p { font-size: 15px; opacity: .85; margin: 0 0 28px; }
.features { list-style: none; padding: 0; margin: 0; }
.features li {
  font-size: 14px; opacity: .9; padding: 8px 0 8px 26px; position: relative;
}
.features li::before {
  content: '✓'; position: absolute; left: 0; top: 8px;
  width: 18px; height: 18px; border-radius: 50%;
  background: rgba(255, 255, 255, .22); font-size: 11px;
  display: flex; align-items: center; justify-content: center;
}
.copyright { font-size: 12px; opacity: .6; }

/* 右侧表单区 */
.form-side {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 40px;
}
.form-box { width: 340px; }
.form-box h2 { font-size: 26px; margin: 0 0 6px; }
.sub { color: #8a90a2; margin: 0 0 28px; }
.login-btn { width: 100%; font-size: 16px; letter-spacing: 4px; margin-top: 4px; }
.tip { margin-top: 20px; font-size: 12px; color: #9aa0b0; text-align: center; }
.tip code { background: #eef0f7; padding: 1px 6px; border-radius: 4px; color: var(--brand-1); }

@media (max-width: 860px) {
  .brand { display: none; }
}
</style>
