export const CONFIG_ENVIRONMENT_OPTIONS = [
  { id: 'test', name: '测试' },
  { id: 'pre', name: '预发' },
  { id: 'prod', name: '正式' }
];

export function adminPathname() {
  if (typeof window === 'undefined') return '/';
  return String(window.location.pathname || '/').replace(/\/+$/, '') || '/';
}

export function adminViewMode() {
  const path = adminPathname();
  if (path === '/test' || path === '/pre' || path === '/prod') return path.slice(1);
  if (path === '/app' || path === '/apps') return 'all';
  return 'picker';
}

export function adminViewLocked() {
  const mode = adminViewMode();
  return mode === 'test' || mode === 'pre' || mode === 'prod';
}

export function adminShowsAll() {
  return adminViewMode() === 'all';
}

export function defaultViewEnvironment() {
  const mode = adminViewMode();
  if (mode === 'test' || mode === 'pre' || mode === 'prod') return mode;
  return 'test';
}

export function ensureAppsHash() {
  if (typeof window === 'undefined') return;
  const path = adminPathname();
  if (!['/app', '/apps', '/test', '/pre', '/prod'].includes(path)) return;
  if (!window.location.hash || window.location.hash === '#') {
    window.location.hash = '#/apps';
  }
}

export function environmentLabel(id) {
  return CONFIG_ENVIRONMENT_OPTIONS.find((item) => item.id === id)?.name || id;
}
