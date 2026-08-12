import { defineStore, acceptHMRUpdate } from 'pinia';
import { ref } from 'vue';
import api from '../api';

// Setup Store:管理后台配置(应用 / 黑名单 / 设置 / 版本)
export const useConfigStore = defineStore('config', () => {
  const apps = ref([]);
  const blockHosts = ref([]);
  const defaultSettings = { diskCapMB: 160, docCheckSec: 60, configRefreshSec: 300, bundleConcurrency: 3, bytecodeCache: true };
  const settings = ref({ ...defaultSettings });
  const version = ref('');
  const loading = ref(false);

  async function load() {
    loading.value = true;
    try {
      const { data } = await api.get('/api/admin/config');
      apps.value = data.apps || [];
      blockHosts.value = data.blockHosts || [];
      settings.value = { ...defaultSettings, ...(data.settings || {}) };
      version.value = data.version || '';
    } finally {
      loading.value = false;
    }
  }

  async function saveApps() {
    const { data } = await api.put('/api/admin/apps', { apps: apps.value });
    version.value = data.version;
    // 后端会对"新加的 bundle:true 且还没离线包的站"自动在后台构建离线包,返回其 id 列表
    return data.autoBuilding || [];
  }
  async function saveBlockHosts() {
    const { data } = await api.put('/api/admin/blockhosts', { blockHosts: blockHosts.value });
    version.value = data.version;
  }
  async function saveSettings() {
    const { data } = await api.put('/api/admin/settings', { settings: settings.value });
    version.value = data.version;
  }

  return { apps, blockHosts, settings, version, loading, load, saveApps, saveBlockHosts, saveSettings };
});

if (import.meta.hot) {
  import.meta.hot.accept(acceptHMRUpdate(useConfigStore, import.meta.hot));
}
