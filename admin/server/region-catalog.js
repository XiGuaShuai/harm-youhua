// 业务后台 test/pre/prod 的国家级地区 ID 并不完全相同。
// 短 ID（如 100016 新加坡）三环境共用；美国/加拿大等雪花 ID 每个环境各有一套。
// 管理端必须按 ID 区分，不能把不同环境的同一个国家显示成两个一模一样的「美国」。

export const ENVIRONMENT_LABELS = {
  test: '测试',
  pre: '预发',
  prod: '正式'
};

export const FIFA_US_REGION_IDS = [
  '2037443812888760321', // 测试
  '2039265040891826177', // 预发
  '2046772885148901377'  // 正式
];

export const REGION_CATALOG = {
  '100003': { name: '泰国', nameEn: 'Thailand', environments: ['test', 'pre', 'prod'] },
  '100004': { name: '中国香港', nameEn: 'Hong Kong, China', environments: ['test', 'pre', 'prod'] },
  '100006': { name: '韩国', nameEn: 'Korea', environments: ['test', 'pre', 'prod'] },
  '100009': { name: '中国澳门', nameEn: 'Macao, China', environments: ['test', 'pre', 'prod'] },
  '100014': { name: '马来西亚', nameEn: 'Malaysia', environments: ['test', 'pre', 'prod'] },
  '100016': { name: '新加坡', nameEn: 'Singapore', environments: ['test', 'pre', 'prod'] },
  '100017': { name: '日本', nameEn: 'Japan', environments: ['test', 'pre', 'prod'] },
  '100106': { name: '越南', nameEn: 'Vietnam', environments: ['test', 'pre', 'prod'] },
  '100253': { name: '阿联酋', nameEn: 'United Arab Emirates', environments: ['test', 'pre', 'prod'] },
  '100296': { name: '西班牙', nameEn: 'Spain', environments: ['test', 'pre', 'prod'] },
  '100452': { name: '俄罗斯', nameEn: 'Russia', environments: ['test', 'pre', 'prod'] },
  '100678': { name: '迪拜', nameEn: 'Dubai', environments: ['test', 'pre', 'prod'] },
  '101422': { name: '阿布扎比', nameEn: 'Abu Dhabi', environments: ['test', 'pre', 'prod'] },

  '1988526837953462273': { name: '印度尼西亚', nameEn: 'Indonesia', environments: ['test'] },
  '1991803082722942977': { name: '印度尼西亚', nameEn: 'Indonesia', environments: ['pre'] },
  '1999320112476409857': { name: '印度尼西亚', nameEn: 'Indonesia', environments: ['prod'] },

  '2007696801692241922': { name: '菲律宾', nameEn: 'Philippines', environments: ['test'] },
  '2009547296843898881': { name: '菲律宾', nameEn: 'Philippines', environments: ['pre'] },
  '2012042556907646977': { name: '菲律宾', nameEn: 'Philippines', environments: ['prod'] },

  '2029440844149977090': { name: '英国', nameEn: 'United Kingdom', environments: ['pre'] },
  '2033730461761748994': { name: '英国', nameEn: 'United Kingdom', environments: ['prod'] },
  '2036722743924088834': { name: '英国', nameEn: 'United Kingdom', environments: ['test'] },

  '2037443325779070977': { name: '加拿大', nameEn: 'Canada', environments: ['test'] },
  '2042137002601316353': { name: '加拿大', nameEn: 'Canada', environments: ['pre'] },
  '2058816112630620162': { name: '加拿大', nameEn: 'Canada', environments: ['prod'] },

  '2037443812888760321': { name: '美国', nameEn: 'United States', environments: ['test'] },
  '2039265040891826177': { name: '美国', nameEn: 'United States', environments: ['pre'] },
  '2046772885148901377': { name: '美国', nameEn: 'United States', environments: ['prod'] },

  '2048685521584848897': { name: '墨西哥', nameEn: 'Mexico', environments: ['test'] },
  '2052639855388274689': { name: '墨西哥', nameEn: 'Mexico', environments: ['pre'] },
  '2054479636581269506': { name: '墨西哥', nameEn: 'Mexico', environments: ['prod'] },

  '2065001517425717249': { name: '德国', nameEn: 'Germany', environments: ['test'] },
  '2065025265867309057': { name: '德国', nameEn: 'Germany', environments: ['pre'] },
  '2070339959066394626': { name: '德国', nameEn: 'Germany', environments: ['prod'] }
};

const KNOWN_COUNTRY_NAMES = new Set(Object.values(REGION_CATALOG).map((item) => item.name));

export function catalogEntryOf(id) {
  return REGION_CATALOG[String(id || '').trim()] || null;
}

export function catalogNameOf(id) {
  const entry = catalogEntryOf(id);
  return entry ? entry.name : '';
}

export function looksLikePlaceholderText(value) {
  const s = String(value || '').trim();
  if (!s) return true;
  return /^[?\s._()（）-]+$/.test(s);
}

export function isLikelyAppTitle(name, appName = '') {
  const s = String(name || '').trim();
  if (!s) return false;
  if (appName && s === String(appName).trim()) return true;
  return /world\s*cup|get\s*your\s*guide|^xe$/i.test(s);
}

export function stripEnvironmentSuffix(name) {
  return String(name || '')
    .replace(/\s*·\s*\d{6,}\s*$/u, '')
    .replace(/\s*·\s*(测试|预发|正式)(\s*\/\s*(测试|预发|正式))*\s*$/u, '')
    .replace(/\s*·\s*\d{6,}\s*$/u, '')
    .trim();
}

export function idsForRegionName(name) {
  const target = String(name || '').trim();
  if (!target) return [];
  return Object.keys(REGION_CATALOG).filter((id) => REGION_CATALOG[id].name === target);
}

export function resolveRegionName(id, storedName = '', extras = {}) {
  const catalogName = catalogNameOf(id);
  const stored = stripEnvironmentSuffix(storedName);
  if (stored && !looksLikePlaceholderText(stored) && !isLikelyAppTitle(stored, extras.appName)) {
    if (catalogName && KNOWN_COUNTRY_NAMES.has(stored) && stored !== catalogName) {
      return catalogName;
    }
    return stored;
  }
  return catalogName || '';
}

export function regionBelongsToEnvironment(id, environment) {
  const entry = catalogEntryOf(id);
  if (!entry || !Array.isArray(entry.environments) || entry.environments.length === 0) return true;
  return entry.environments.includes(String(environment || '').trim());
}

export function selectRegionIdsForEnvironment(regionIds, environment, extras = {}) {
  const groups = new Map();
  for (const value of regionIds || []) {
    const id = String(value || '').trim();
    if (!id) continue;
    const name = resolveRegionName(id, extras.regionNames ? extras.regionNames[id] : '', extras) || id;
    if (!groups.has(name)) groups.set(name, []);
    groups.get(name).push(id);
  }
  const result = [];
  for (const ids of groups.values()) {
    if (ids.length === 1) {
      result.push(ids[0]);
      continue;
    }
    const matched = ids.filter((id) => regionBelongsToEnvironment(id, environment));
    result.push(matched[0] || ids[0]);
  }
  return result;
}

export function displayRegionMeta(id, storedName = '', extras = {}) {
  const rawId = String(id || '').trim();
  const name = resolveRegionName(rawId, storedName, extras);
  const scoped = !!extras.viewEnvironment;
  const colliding = !scoped && !!(name && idsForRegionName(name).length > 1);
  const entry = catalogEntryOf(rawId);
  const envText = colliding
    ? (entry && entry.environments ? entry.environments : [])
      .map((environment) => ENVIRONMENT_LABELS[environment])
      .filter(Boolean)
      .join('/')
    : '';
  const shortTitle = envText ? `${name} · ${envText}` : (name || (rawId ? `地区 ${rawId}` : '地区'));
  const title = colliding ? `${shortTitle} · ${rawId}` : shortTitle;
  return {
    id: rawId,
    name: name || '',
    envText,
    colliding,
    shortTitle,
    title
  };
}

export function displayRegionName(id, storedName = '', extras = {}) {
  return displayRegionMeta(id, storedName, extras).title;
}

export function ensureFifaEnvironmentRegions(regionIds) {
  const seen = new Set();
  const result = [];
  for (const value of [...(regionIds || []), ...FIFA_US_REGION_IDS]) {
    const id = String(value || '').trim();
    if (!id || seen.has(id)) continue;
    seen.add(id);
    result.push(id);
  }
  return result;
}
