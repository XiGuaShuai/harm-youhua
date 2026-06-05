import axios from 'axios';

// axios 实例:自动带上后台 token;401 时跳回登录
const api = axios.create();

api.interceptors.request.use((cfg) => {
  const t = localStorage.getItem('admin_token');
  if (t) cfg.headers['X-Admin-Token'] = t;
  return cfg;
});

api.interceptors.response.use(
  (res) => res,
  (err) => {
    if (err.response && err.response.status === 401) {
      localStorage.removeItem('admin_token');
      localStorage.removeItem('admin_user');
      location.reload();
    }
    return Promise.reject(err);
  }
);

export default api;
