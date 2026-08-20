import { createApp } from 'vue';
import { createPinia } from 'pinia';
import ElementPlus from 'element-plus';
import 'element-plus/dist/index.css';
import * as ElementPlusIconsVue from '@element-plus/icons-vue';
import './styles.css';
import App from './App.vue';
import router from './router';

const adminPath = window.location.pathname.replace(/\/+$/, '') || '/';
if ((adminPath === '/app' || adminPath === '/apps') && (!window.location.hash || window.location.hash === '#')) {
  window.location.hash = '#/apps';
}

const app = createApp(App);
for (const [name, comp] of Object.entries(ElementPlusIconsVue)) app.component(name, comp);
app.use(createPinia()).use(router).use(ElementPlus).mount('#app');
