import { defineStore, acceptHMRUpdate } from 'pinia';
import { ref, computed } from 'vue';
import axios from 'axios';
import api from '../api';

// 登录态:账号 / 会话 token,登录、退出、改密
export const useAuthStore = defineStore('auth', () => {
  const token = ref(localStorage.getItem('admin_token') || '');
  const username = ref(localStorage.getItem('admin_user') || '');
  const authed = computed(() => !!token.value);

  async function login(u, p) {
    const { data } = await axios.post('/api/login', { username: u, password: p });
    token.value = data.token;
    username.value = data.username;
    localStorage.setItem('admin_token', data.token);
    localStorage.setItem('admin_user', data.username);
    return data;
  }

  async function logout() {
    try { await api.post('/api/logout'); } catch { /* 忽略 */ }
    token.value = '';
    username.value = '';
    localStorage.removeItem('admin_token');
    localStorage.removeItem('admin_user');
  }

  async function changePassword(oldPassword, newPassword) {
    await api.post('/api/admin/password', { oldPassword, newPassword });
  }

  return { token, username, authed, login, logout, changePassword };
});

if (import.meta.hot) {
  import.meta.hot.accept(acceptHMRUpdate(useAuthStore, import.meta.hot));
}
