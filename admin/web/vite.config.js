import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

// 开发时把 /api 和 /bundles 代理到后端(默认 8787)
export default defineConfig({
  plugins: [vue()],
  server: {
    port: 5174,
    proxy: {
      '/api': 'http://localhost:8787',
      '/bundles': 'http://localhost:8787'
    }
  }
});
