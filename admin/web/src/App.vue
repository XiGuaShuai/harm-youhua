<script setup>
import { computed, ref, onBeforeUnmount, onMounted, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { storeToRefs } from 'pinia';
import {
  Odometer, Grid, Document, CircleClose, Box, Setting,
  SwitchButton, Key, CaretBottom
} from '@element-plus/icons-vue';
import { useConfigStore } from './stores/config';
import { useAuthStore } from './stores/auth';
import { adminShowsAll, adminViewLocked, defaultViewEnvironment, environmentLabel } from './adminPath';
import LoginView from './components/LoginView.vue';
import ChangePassword from './components/ChangePassword.vue';

const route = useRoute();
const router = useRouter();
const store = useConfigStore();
const auth = useAuthStore();
const { version } = storeToRefs(store);
const { authed, username, ready: authReady, localDemo } = storeToRefs(auth);

const pwDialog = ref(false);
const pathLocked = adminViewLocked();
const pathShowsAll = adminShowsAll();
const pathEnvName = environmentLabel(defaultViewEnvironment());
const environmentView = pathLocked;

const allMenus = [
  { path: '/dashboard', title: '概览', icon: Odometer },
  { path: '/apps', title: '应用管理', icon: Grid },
  { path: '/config-json', title: '更新 JSON', icon: Document },
  { path: '/blocklist', title: '过滤黑名单', icon: CircleClose },
  { path: '/bundles', title: '离线包', icon: Box },
  { path: '/settings', title: '全局设置', icon: Setting }
];
const menus = environmentView
  ? allMenus.filter((item) => item.path === '/apps')
  : allMenus;

const pageTitle = computed(() => environmentView && route.path === '/config-json' ? '更新 JSON' : route.meta.title);
const pageDescription = computed(() => environmentView && route.path === '/config-json'
  ? `通过已配置账号和接口更新${pathEnvName}环境应用 JSON，并同步覆盖应用关联的全部地区`
  : route.meta.desc);

watch(
  () => route.path,
  (path) => {
    if (environmentView && path !== '/apps') router.replace('/apps');
  },
  { immediate: true }
);

function onLoggedIn() { store.load(); }
function logout() { auth.logout().then(() => { /* authed 变 false 自动回登录页 */ }); }

onMounted(async () => {
  if (environmentView) document.body.classList.add('environment-admin');
  await auth.bootstrap();
  if (authed.value) store.load();
});
onBeforeUnmount(() => document.body.classList.remove('environment-admin'));
</script>

<template>
  <div v-if="!authReady"></div>
  <LoginView v-else-if="!authed" @done="onLoggedIn" />

  <el-container v-else class="layout">
    <!-- 侧边栏 -->
    <el-aside width="220px" class="aside">
      <div class="logo">
        <svg viewBox="0 0 24 24" width="22" height="22" fill="#fff"><path d="M13 2 3 14h7l-1 8 11-13h-8z"/></svg>
        <span>网页加速后台</span>
      </div>
      <el-menu :default-active="route.path" router class="menu">
        <el-menu-item v-for="m in menus" :key="m.path" :index="m.path">
          <el-icon><component :is="m.icon" /></el-icon>
          <span>{{ m.title }}</span>
        </el-menu-item>
      </el-menu>
      <div class="aside-foot">v1.0 · 远程配置中心</div>
    </el-aside>

    <el-container>
      <!-- 顶栏 -->
      <el-header class="header">
        <div class="title-wrap">
          <div class="title">{{ pageTitle }}</div>
          <div class="desc">{{ pageDescription }}</div>
        </div>
        <div class="right">
          <el-tag v-if="pathShowsAll" size="small" type="warning" effect="plain" round>备份总览</el-tag>
          <el-tag v-else-if="pathLocked" size="small" type="warning" effect="plain" round>{{ pathEnvName }}环境</el-tag>
          <el-tag size="small" type="info" effect="plain" round>
            配置版本 {{ version ? version.slice(0, 19).replace('T', ' ') : '-' }}
          </el-tag>
          <el-tag v-if="localDemo" size="small" type="success" effect="plain" round>本地免登录</el-tag>
          <el-dropdown v-else trigger="click">
            <span class="user">
              <el-avatar :size="30" class="avatar">{{ (username || 'A').charAt(0).toUpperCase() }}</el-avatar>
              <span class="uname">{{ username || 'admin' }}</span>
              <el-icon><CaretBottom /></el-icon>
            </span>
            <template #dropdown>
              <el-dropdown-menu>
                <el-dropdown-item :icon="Key" @click="pwDialog = true">修改密码</el-dropdown-item>
                <el-dropdown-item :icon="SwitchButton" divided @click="logout">退出登录</el-dropdown-item>
              </el-dropdown-menu>
            </template>
          </el-dropdown>
        </div>
      </el-header>

      <!-- 内容 -->
      <el-main class="main">
        <router-view v-slot="{ Component }">
          <transition name="fade" mode="out-in">
            <component :is="Component" />
          </transition>
        </router-view>
      </el-main>
    </el-container>

    <ChangePassword v-model="pwDialog" />
  </el-container>
</template>

<style scoped>
.layout { height: 100vh; }

/* 侧边栏 */
.aside {
  background: #1b1f31;
  display: flex;
  flex-direction: column;
}
.logo {
  display: flex; align-items: center; gap: 10px;
  color: #fff; font-weight: 700; font-size: 16px;
  padding: 0 20px; height: 64px;
  background: rgba(255, 255, 255, .03);
  border-bottom: 1px solid rgba(255, 255, 255, .06);
}
.menu { flex: 1; background: transparent; border: none; padding: 10px 12px; }
.menu .el-menu-item {
  color: #aeb4c7; border-radius: 8px; margin: 4px 0; height: 46px;
}
.menu .el-menu-item:hover { color: #fff; background: rgba(255, 255, 255, .06); }
.menu .el-menu-item.is-active {
  color: #fff; background: var(--brand-grad);
  box-shadow: 0 4px 12px rgba(79, 91, 213, .4);
}
.aside-foot { color: #5a6079; font-size: 12px; text-align: center; padding: 16px; }

/* 顶栏 */
.header {
  height: 64px;
  display: flex; align-items: center; justify-content: space-between;
  background: #fff; border-bottom: 1px solid #edf0f5;
  box-shadow: 0 1px 4px rgba(31, 36, 51, .03);
}
.title-wrap { line-height: 1.25; }
.title { font-size: 17px; font-weight: 700; color: #1f2433; }
.desc { font-size: 12px; color: #9aa0b0; margin-top: 2px; }
.right { display: flex; align-items: center; gap: 16px; }
.user { display: flex; align-items: center; gap: 8px; cursor: pointer; outline: none; }
.avatar { background: var(--brand-grad); color: #fff; font-weight: 600; }
.uname { font-size: 14px; color: #41475a; }

/* 内容区 */
.main { background: var(--app-bg); padding: 22px; }

.fade-enter-active, .fade-leave-active { transition: opacity .18s ease; }
.fade-enter-from, .fade-leave-to { opacity: 0; }
</style>
