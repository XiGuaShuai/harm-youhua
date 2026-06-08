import { createRouter, createWebHashHistory } from 'vue-router';

const routes = [
  { path: '/', redirect: '/dashboard' },
  { path: '/dashboard', name: 'dashboard', component: () => import('../views/Dashboard.vue'),
    meta: { title: '概览', desc: '配置总览与服务状态' } },
  { path: '/apps', name: 'apps', component: () => import('../views/Apps.vue'),
    meta: { title: '应用管理', desc: '管理网页应用、加速开关与路由列表' } },
  { path: '/blocklist', name: 'blocklist', component: () => import('../views/Blocklist.vue'),
    meta: { title: '过滤黑名单', desc: '命中即秒拒的第三方域名/路径' } },
  { path: '/bundles', name: 'bundles', component: () => import('../views/Bundles.vue'),
    meta: { title: '离线包', desc: '服务器缓存清单与拉取地址' } },
  { path: '/settings', name: 'settings', component: () => import('../views/Settings.vue'),
    meta: { title: '全局设置', desc: '缓存上限、版本校验节流等下发参数' } }
];

export default createRouter({ history: createWebHashHistory(), routes });
