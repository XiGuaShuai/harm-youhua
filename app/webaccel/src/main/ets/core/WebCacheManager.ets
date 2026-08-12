import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { WebNetErrorList, webview } from '@kit.ArkWeb';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RemoteSettings, RemoteApp, remoteAppRegions } from './RemoteConfig';

const TAG: string = 'WebCache';
const DOMAIN: number = 0x0001;
const DISK_CAP_BYTES: number = 160 * 1024 * 1024;   // 沙箱离线包总量上限
const BUNDLE_CONCURRENCY: number = 8;               // 远程离线包后台下载并发上限(可远程下发覆盖,上限 8)

/**
 * SDK 内置的极小「首启安全网」黑名单 —— **不是站点优化**。
 * 只放会**阻塞渲染 / 挂死 window.load** 且跨境普遍不可达的通用域,保证「后台配置还没拉到 /
 * 后台不可达」的窗口里首启也不卡。完整、可调的黑名单由 **admin 后台下发**:
 * `setBlockHosts(非空)` 会整体覆盖本列表(见 intercept 用的 this.blockHosts)。
 * 给某个站加屏蔽域 → 改 admin 配置,不要往这里加。
 * 注意:不要放 recaptcha / maps / 支付等功能性第三方(屏蔽会破坏功能)。
 */
const BLOCK_HOSTS: string[] = [
  'translate.google', 'translate.googleapis',     // 谷歌翻译挂件:阻塞渲染 + 国内不可达
  'fonts.googleapis.com', 'fonts.gstatic.com',    // 谷歌字体:阻塞渲染(降级系统字体)
  'google-analytics.com', 'googletagmanager.com', // GA/GTM:会挂起到超时
  'doubleclick.net'                               // 广告:常挂起
];

/** 后台离线包 manifest 资源项 */
interface RawEntry {
  url: string;
  file: string;
  mime: string;
  size?: number;
  doc?: boolean;     // true = backend explicitly marked HTML document/fragment for offline caching
  encoding?: string; // zlib: local file is compressed; decode before serving to WebView
  rawSize?: number;  // 原始大小,仅用于统计/排查
}

interface RemoteManifestObject {
  configJson?: string;
  webConfigJson?: string;
  resources?: RawEntry[];
  manifest?: RawEntry[];
}

/** 沙箱离线包索引,可写,带 LRU 字段 */
interface DiskEntry {
  url: string;
  file: string;
  mime: string;
  size: number;
  atime: number;    // 最近访问时间,用于 LRU
  storedAt: number; // 最近写入时间,用于主文档版本校验节流
  version: string;  // 内容指纹,用于检测主文档(版本)是否变化
  costMs?: number;  // 本次写入时的下载耗时,用于评估"慢资源是否值得缓存"
  source?: string;  // runtime / bundle / doc
  encoding?: string; // zlib: local file is compressed; decode before serving to WebView
  rawSize?: number;  // 原始大小,统计用
  bundleId?: string; // 后台网址 id,用于按 id 删除/查配置
  region?: string;   // 地区 id,用于地区切换时删除旧地区缓存
  scope?: string;    // top / region
}

/** 调试用统计 */
export interface CacheStats {
  raw: number;          // 内置包条数
  disk: number;         // 沙箱缓存条数
  hitRaw: number;       // 兼容字段，固定为 0
  hitDisk: number;      // 命中沙箱次数
  miss: number;         // 透传次数
  blocked: number;      // 短路掉的外部挂起请求次数
  bytes: number;        // 沙箱已用字节
  // —— 后台缓存活动(用于"是否在背后偷偷再缓存")——
  inflight: number;     // 正在下载回填的资源数
  pending: number;      // 兼容字段，固定为 0
  bundleActive: number; // 离线包正在下载的资源数
  bundleQueued: number; // 离线包排队待下的资源数
  lastUrl: string;      // 最近被后台缓存的资源 URL(看"在缓存哪个站的什么资源")
  recent: string[];     // 最近若干条后台缓存的 URL(新→旧),用于浮窗列出多个
  caching: boolean;     // 是否"真的还在缓存"(最近 3 秒内有缓存成功;挂死的请求不算)
}

/** 某站离线包下载进度(对外只读) */
export interface BundleProgress {
  total: number; // 该站离线包资源总数
  done: number;  // 已就绪(已缓存或刚下完)数
}

/** 内部进度记录:expected 为"还没下、待完成"的原站 URL 集合 */
interface BundleProgressEntry {
  total: number;
  done: number;
  expected: Set<string>;
}

/** 离线包已应用状态(持久化):支撑"版本门 + 按 URL 增删"的更新检查 */
interface BundleState {
  key?: string;     // 新版持久化 key: 优先 appId,无 appId 时用 origin。兼容老版本没有 key 的状态
  id?: string;      // 后台网址 id
  origin: string;
  region?: string;
  scope?: string;
  version: string; // 已应用的 bundleVersion(与 /api/config 下发的对比,一致则跳过更新)
  urls: string[];  // 已应用清单里的资源 URL(用于清理被服务端移除的旧资源)
  configJson?: string; // 该网址对应的 H5 配置 JSON,供宿主离线兜底注入
}

/** 离线包资源损坏 → 后台自愈上报体 */
interface SelfHealBody {
  appId: string;
  reason: string;
}

interface BundleResourceOwner {
  bundleKey: string;
  bundleId: string;
  origin: string;
  region: string;
  scope: string;
  generation: number;
}

interface SchemeHit {
  body: ArrayBuffer;
  mime: string;
}

/**
 * 后台离线包管理器。资源只从后台 manifest 下载到沙箱，未命中请求直接走网络。
 */
class WebCacheManager {
  private cacheDir: string = '';
  private indexPath: string = '';

  private blockHosts: string[] = BLOCK_HOSTS;       // 过滤黑名单(可远程下发)
  private diskCapBytes: number = DISK_CAP_BYTES;    // 沙箱缓存上限(可远程下发)
  private bundleConcurrency: number = BUNDLE_CONCURRENCY; // 远程离线包下载并发(可远程下发)
  private mergedBlockByOrigin: Map<string, string[]> = new Map();
  private uaByOrigin: Map<string, string> = new Map();        // 该应用的自定义 UA(覆盖默认手机化 UA;按 origin 索引)
  private bundleAppByOrigin: Map<string, string> = new Map(); // origin → appId(仅 bundle:true 的站):离线包资源丢失自愈上报用
  private bundleScopeByOrigin: Map<string, string> = new Map();
  private bundleRegionByOrigin: Map<string, string> = new Map();
  private bundleRegionsByOrigin: Map<string, string[]> = new Map();
  private appOriginById: Map<string, string> = new Map();
  private appScopeById: Map<string, string> = new Map();
  private appRegionById: Map<string, string> = new Map();
  private appRegionsById: Map<string, string[]> = new Map();
  private reportedSelfHeal: Set<string> = new Set();          // 已上报过自愈的 appId(本次会话只报一次,防刷)
  private serverBase: string = '';                            // 后端地址(applyApps 时由 remoteConfig.getServer() 注入,自愈上报用)

  private diskIndex: Map<string, DiskEntry> = new Map();
  private inflight: Set<string> = new Set();
  private bundleQueue: RawEntry[] = [];
  private bundleQueueSources: Map<string, string> = new Map();
  private bundleQueueOwners: Map<string, BundleResourceOwner> = new Map();
  private activeBundleDownloads: number = 0;
  private totalBytes: number = 0;
  private ready: boolean = false;

  private hitDisk: number = 0;
  private miss: number = 0;
  private blocked: number = 0;
  private loadedBundles: Set<string> = new Set();                 // 本次会话已拉过远程离线包的 key(appId 或 origin)
  private pendingBundleVersionByKey: Map<string, string> = new Map(); // 兜底配置先拉包、远程配置后到时暂存版本号
  private bundleProgress: Map<string, BundleProgressEntry> = new Map(); // 各站离线包下载进度(按 origin)
  private bundleErrors: Map<string, string> = new Map();                // 各站离线包最近一次失败原因(调试浮窗用)
  private bundleState: Map<string, BundleState> = new Map();      // 各站离线包已应用状态(版本+URL清单,持久化,用于更新检查)
  private bundleStatePath: string = '';                           // bundle-state.json 路径
  private decodedMemory: Map<string, ArrayBuffer> = new Map();     // decoded compressed bundle bytes; memory only
  private decoding: Set<string> = new Set();                       // URLs currently being decoded
  private lastCachedUrl: string = '';                             // 最近被后台缓存的资源 URL(调试浮窗用)
  private recentCached: string[] = [];                            // 最近若干条后台缓存(新→旧,调试浮窗列表用)
  private lastCacheAt: number = 0;                                // 最近一次"缓存成功"的时刻(判断是否真的还在缓存)
  private activeRegion: string = '';                              // 当前独占地区缓存
  private regionGeneration: number = 0;                            // 地区切换代号,旧任务回调用它判废

  /** 启动时调用一次(EntryAbility.onCreate) */
  init(context: common.UIAbilityContext): void {
    try {
      this.cacheDir = context.filesDir + '/webcache';
      this.indexPath = this.cacheDir + '/index.json';
      this.bundleStatePath = this.cacheDir + '/bundle-state.json';
      if (!fs.accessSync(this.cacheDir)) {
        fs.mkdirSync(this.cacheDir, true);
      }
      this.loadDiskIndex();
      this.loadBundleState();
      this.ready = true;
      hilog.info(DOMAIN, TAG, 'ready, disk=%{public}d bytes=%{public}d',
        this.diskIndex.size, this.totalBytes);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', err.message);
    }
  }

  /** 远程下发过滤黑名单(覆盖默认内置列表;传空则保留默认) */
  setBlockHosts(hosts: string[]): void {
    if (hosts && hosts.length > 0) {
      this.blockHosts = hosts;
      hilog.info(DOMAIN, TAG, 'blockHosts injected: %{public}d', hosts.length);
    }
  }

  /**
   * 应用每应用精细配置:按 origin 预算"全局黑名单 + 该应用 extraBlockHosts"的合并列表,
   * UA 和离线包归属也在这里按 origin / app id 建索引。
   * 必须在 setBlockHosts 之后调用(依赖全局黑名单做合并)。
   */
  applyApps(apps: RemoteApp[], server: string = ''): void {
    this.mergedBlockByOrigin.clear();
    this.uaByOrigin.clear();
    this.bundleAppByOrigin.clear();
    this.bundleScopeByOrigin.clear();
    this.bundleRegionByOrigin.clear();
    this.bundleRegionsByOrigin.clear();
    this.appOriginById.clear();
    this.appScopeById.clear();
    this.appRegionById.clear();
    this.appRegionsById.clear();
    if (server && server.length > 0) {
      this.serverBase = server.replace(/\/+$/, '');
    }
    if (!apps || apps.length === 0) {
      return;
    }
    for (let i = 0; i < apps.length; i++) {
      const app: RemoteApp = apps[i];
      if (!app || !app.url || app.url.length === 0) {
        continue;
      }
      const om = app.url.match(/^https?:\/\/[^\/]+/);
      const origin: string = om ? om[0] : '';
      if (origin.length === 0) {
        continue;
      }
      const scope: string = app.scope && app.scope.length > 0 ? app.scope : '';
      const regions: string[] = remoteAppRegions(app);
      const region: string = regions.length > 0 ? regions[0] : '';
      this.bundleScopeByOrigin.set(origin, scope);
      this.bundleRegionByOrigin.set(origin, region);
      this.bundleRegionsByOrigin.set(origin, regions.slice());
      if (app.id && app.id.length > 0) {
        this.appOriginById.set(app.id, origin);
        this.appScopeById.set(app.id, scope);
        this.appRegionById.set(app.id, region);
        this.appRegionsById.set(app.id, regions.slice());
      }
      if (app.appId && app.appId.length > 0) {
        this.appOriginById.set(app.appId, origin);
        this.appScopeById.set(app.appId, scope);
        this.appRegionById.set(app.appId, region);
        this.appRegionsById.set(app.appId, regions.slice());
      }
      // 合并黑名单 = 全局 + 该应用额外
      const merged: string[] = this.blockHosts.slice();
      if (app.extraBlockHosts && app.extraBlockHosts.length > 0) {
        for (let j = 0; j < app.extraBlockHosts.length; j++) {
          const h: string = app.extraBlockHosts[j];
          if (h && h.length > 0) {
            merged.push(h);
          }
        }
      }
      this.mergedBlockByOrigin.set(origin, merged);
      if (app.extraBlockHosts && app.extraBlockHosts.length > 0) {
        for (let j = 0; j < app.extraBlockHosts.length; j++) {
          const h: string = app.extraBlockHosts[j];
          const hm = h.match(/^https?:\/\/[^\/]+/);
          let blockOrigin: string = hm ? hm[0] : '';
          if (blockOrigin.length === 0 && h.indexOf('.') > 0 && h.indexOf('/') < 0) {
            blockOrigin = 'https://' + h;
          }
          if (blockOrigin.length > 0 && !this.mergedBlockByOrigin.has(blockOrigin)) {
            this.mergedBlockByOrigin.set(blockOrigin, merged);
          }
        }
      }
      // 每应用自定义 UA(非空才记录;覆盖默认手机化逻辑)
      if (app.userAgent && app.userAgent.length > 0) {
        this.uaByOrigin.set(origin, app.userAgent);
      }
      // 运行时静态资源自动缓存已禁用。端侧只下载后台 manifest 中的离线包资源。
      // 仅 bundle:true 的站记 origin→appId,用于"离线包资源实际读不出→上报后台自愈"
      if (app.bundle === true && app.id && app.id.length > 0) {
        this.bundleAppByOrigin.set(origin, app.id);
      }
      if (app.id && app.id.length > 0) {
        this.updateConfigJson(app.id, app.configJson ? app.configJson : '');
      }
    }
    hilog.info(DOMAIN, TAG, 'applyApps: %{public}d origins', this.mergedBlockByOrigin.size);
  }

  /** 取某 URL 对应的合并黑名单(全局+该应用额外);无应用匹配时退回全局 */
  private blockListFor(url: string): string[] {
    const om = url.match(/^https?:\/\/[^\/]+/);
    const origin: string = om ? om[0] : '';
    if (origin.length > 0) {
      const merged: string[] | undefined = this.mergedBlockByOrigin.get(origin);
      if (merged) {
        return merged;
      }
    }
    return this.blockHosts;
  }

  /**
   * 取某 URL 所属应用的自定义 UA(后台 app.userAgent 下发);未配置返回空串。
   * WebShared 在 onControllerAttached 据此决定:有自定义 UA → 用它(覆盖手机化);否则走默认手机化逻辑。
   */
  userAgentFor(url: string): string {
    const om = url.match(/^https?:\/\/[^\/]+/);
    const origin: string = om ? om[0] : '';
    if (origin.length > 0) {
      const ua: string | undefined = this.uaByOrigin.get(origin);
      if (ua && ua.length > 0) {
        return ua;
      }
    }
    return '';
  }

  /** 远程下发沙箱上限和离线包下载并发。 */
  applySettings(s: RemoteSettings): void {
    if (!s) {
      return;
    }
    if (typeof s.diskCapMB === 'number' && s.diskCapMB > 0) {
      this.diskCapBytes = s.diskCapMB * 1024 * 1024;
    }
    if (typeof s.bundleConcurrency === 'number' && s.bundleConcurrency > 0) {
      this.bundleConcurrency = Math.max(1, Math.min(8, Math.floor(s.bundleConcurrency)));
    }
    hilog.info(DOMAIN, TAG, 'settings cap=%{public}dB bundleConcurrency=%{public}d',
      this.diskCapBytes, this.bundleConcurrency);
  }

  /** 地区切换:取消旧地区队列、删除旧地区沙箱缓存。top 常驻缓存不受影响 */
  switchRegion(region: string): void {
    const nextRegion: string = region ? region : '';
    if (this.activeRegion === nextRegion && nextRegion.length > 0) {
      return;
    }
    const oldRegion: string = this.activeRegion;
    this.regionGeneration++;
    this.activeRegion = nextRegion;
    // activeRegion is process-local. On a cold start, remove any persisted region cache
    // that does not belong to the newly selected region as well.
    const staleRegions: Set<string> = new Set<string>();
    if (oldRegion.length > 0 && oldRegion !== nextRegion) {
      staleRegions.add(oldRegion);
    }
    this.diskIndex.forEach((entry: DiskEntry) => {
      if (entry.scope === 'region' && entry.region && entry.region.length > 0 && entry.region !== nextRegion) {
        staleRegions.add(entry.region);
      }
    });
    this.bundleState.forEach((state: BundleState) => {
      if (state.scope === 'region' && state.region && state.region.length > 0 && state.region !== nextRegion) {
        staleRegions.add(state.region);
      }
    });
    staleRegions.forEach((staleRegion: string) => {
      this.cancelRegionQueue(staleRegion);
      this.deleteRegion(staleRegion);
    });
    hilog.info(DOMAIN, TAG, 'switchRegion %{public}s -> %{public}s gen=%{public}d',
      oldRegion.length > 0 ? oldRegion : '(none)', nextRegion.length > 0 ? nextRegion : '(none)', this.regionGeneration);
  }

  /** 当前宿主选择的地区 ID。地区离线包必须以该值作为缓存归属。 */
  getActiveRegion(): string {
    return this.activeRegion;
  }

  /** 删除某个地区的离线包缓存。只删 scope=region 的资源,不删 top */
  deleteRegion(region: string): void {
    if (!region || region.length === 0) {
      return;
    }
    const urls: string[] = [];
    this.diskIndex.forEach((v: DiskEntry, k: string) => {
      if (v.scope === 'region' && v.region === region) {
        urls.push(k);
      }
    });
    for (let i = 0; i < urls.length; i++) {
      this.removeCached(urls[i]);
    }
    const stateKeys: string[] = [];
    this.bundleState.forEach((v: BundleState, k: string) => {
      if (v.scope === 'region' && v.region === region) {
        stateKeys.push(k);
      }
    });
    for (let i = 0; i < stateKeys.length; i++) {
      this.bundleState.delete(stateKeys[i]);
      this.bundleProgress.delete(stateKeys[i]);
      this.bundleErrors.delete(stateKeys[i]);
      this.loadedBundles.delete(stateKeys[i]);
    }
    this.saveDiskIndex();
    this.saveBundleState();
    hilog.info(DOMAIN, TAG, 'deleteRegion %{public}s urls=%{public}d bundles=%{public}d',
      region, urls.length, stateKeys.length);
  }

  /** 删除某个网址 id 对应的离线包缓存 */
  deleteBundle(id: string): void {
    if (!id || id.length === 0) {
      return;
    }
    const urls: string[] = [];
    const state: BundleState | undefined = this.bundleState.get(id);
    if (state && state.urls) {
      for (let i = 0; i < state.urls.length; i++) {
        urls.push(state.urls[i]);
      }
    }
    this.diskIndex.forEach((v: DiskEntry, k: string) => {
      if (v.bundleId === id) {
        if (urls.indexOf(k) < 0) {
          urls.push(k);
        }
      }
    });
    for (let i = 0; i < urls.length; i++) {
      this.removeCached(urls[i]);
    }
    this.bundleState.delete(id);
    this.bundleProgress.delete(id);
    this.bundleErrors.delete(id);
    this.loadedBundles.delete(id);
    this.saveDiskIndex();
    this.saveBundleState();
    hilog.info(DOMAIN, TAG, 'deleteBundle %{public}s urls=%{public}d', id, urls.length);
  }

  /** 获取随离线包下发/本地保存的 H5 配置 JSON。接入方可用它做接口失败时的 configJson 兜底 */
  getConfigJson(idOrUrl: string): string {
    if (!idOrUrl || idOrUrl.length === 0) {
      hilog.info(DOMAIN, TAG, 'configJson MISS empty key');
      return '';
    }
    const key: string = this.bundleKeyFor('', idOrUrl);
    const direct: BundleState | undefined = this.bundleState.get(key);
    if (direct && direct.configJson && direct.configJson.length > 0) {
      hilog.info(DOMAIN, TAG, 'configJson HIT key=%{public}s origin=%{public}s bytes=%{public}d',
        key, direct.origin && direct.origin.length > 0 ? direct.origin : '(none)', direct.configJson.length);
      return direct.configJson as string;
    }
    const origin: string = this.originFromUrl(idOrUrl);
    if (origin.length > 0) {
      let found: string = '';
      let foundKey: string = '';
      this.bundleState.forEach((v: BundleState, k: string) => {
        if (found.length === 0 && v.origin === origin && v.configJson && v.configJson.length > 0) {
          found = v.configJson as string;
          foundKey = k;
        }
      });
      if (found.length > 0) {
        hilog.info(DOMAIN, TAG, 'configJson HIT key=%{public}s origin=%{public}s bytes=%{public}d',
          foundKey.length > 0 ? foundKey : key, origin, found.length);
      } else {
        hilog.info(DOMAIN, TAG, 'configJson MISS key=%{public}s origin=%{public}s', key, origin);
      }
      return found;
    }
    hilog.info(DOMAIN, TAG, 'configJson MISS key=%{public}s origin=%{public}s', key, '(none)');
    return '';
  }

  /** 接入方从原业务接口拿到最新 configJson 时可同步进离线状态,下次弱网可兜底使用 */
  updateConfigJson(idOrUrl: string, configJson: string): void {
    if (!idOrUrl || idOrUrl.length === 0) {
      return;
    }
    const key: string = this.bundleKeyFor('', idOrUrl);
    let origin: string = this.originFromUrl(idOrUrl);
    const mappedOrigin: string | undefined = this.appOriginById.get(key);
    if (origin.length === 0 && mappedOrigin !== undefined) {
      origin = mappedOrigin;
    }
    let scope: string = origin.length > 0 && this.bundleScopeByOrigin.get(origin) !== undefined
      ? this.bundleScopeByOrigin.get(origin) as string
      : '';
    let region: string = origin.length > 0 && this.bundleRegionByOrigin.get(origin) !== undefined
      ? this.bundleRegionByOrigin.get(origin) as string
      : '';
    let regions: string[] = origin.length > 0 && this.bundleRegionsByOrigin.get(origin) !== undefined
      ? (this.bundleRegionsByOrigin.get(origin) as string[]).slice()
      : new Array<string>();
    const mappedScope: string | undefined = this.appScopeById.get(key);
    const mappedRegion: string | undefined = this.appRegionById.get(key);
    const mappedRegions: string[] | undefined = this.appRegionsById.get(key);
    if (mappedScope !== undefined && mappedScope.length > 0) {
      scope = mappedScope;
    }
    if (mappedRegion !== undefined && mappedRegion.length > 0) {
      region = mappedRegion;
    }
    if (mappedRegions !== undefined && mappedRegions.length > 0) {
      regions = mappedRegions.slice();
    }
    if (scope === 'region' && this.activeRegion.length > 0) {
      for (let i = 0; i < regions.length; i++) {
        if (regions[i] === this.activeRegion) {
          region = this.activeRegion;
          break;
        }
      }
    }
    const state: BundleState | undefined = this.bundleState.get(key);
    if (state) {
      state.configJson = configJson.length > 0 ? configJson : undefined;
      if (state.origin.length === 0 && origin.length > 0) {
        state.origin = origin;
      }
      if ((!state.scope || state.scope.length === 0) && scope.length > 0) {
        state.scope = this.normalizeScope(scope);
      }
      if ((!state.region || state.region.length === 0) && region.length > 0) {
        state.region = region;
      }
      this.bundleState.set(key, state);
      this.saveBundleState();
      hilog.info(DOMAIN, TAG, 'configJson updated key=%{public}s origin=%{public}s scope=%{public}s region=%{public}s bytes=%{public}d',
        key,
        state.origin && state.origin.length > 0 ? state.origin : '(none)',
        state.scope && state.scope.length > 0 ? state.scope : '(none)',
        state.region && state.region.length > 0 ? state.region : '(none)',
        configJson.length);
      return;
    }
    if (configJson.length === 0) {
      return;
    }
    const fallbackId: string | undefined = origin.length > 0 ? this.bundleAppByOrigin.get(origin) : undefined;
    const saved: BundleState = {
      key: key,
      id: key.indexOf('http://') !== 0 && key.indexOf('https://') !== 0 ? key : (fallbackId !== undefined ? fallbackId : key),
      origin: origin,
      region: region.length > 0 ? region : undefined,
      scope: this.normalizeScope(scope),
      version: '',
      urls: new Array<string>(),
      configJson: configJson
    };
    this.bundleState.set(key, saved);
    this.saveBundleState();
    hilog.info(DOMAIN, TAG, 'configJson saved key=%{public}s origin=%{public}s scope=%{public}s region=%{public}s bytes=%{public}d',
      key,
      origin.length > 0 ? origin : '(none)',
      saved.scope && saved.scope.length > 0 ? saved.scope : '(none)',
      saved.region && saved.region.length > 0 ? saved.region : '(none)',
      configJson.length);
  }

  private originFromUrl(input: string): string {
    if (!input || input.length === 0) {
      return '';
    }
    const om: RegExpMatchArray | null = input.match(/^https?:\/\/[^\/]+/);
    return om ? om[0] : '';
  }

  private bundleKeyFor(origin: string, appId: string = ''): string {
    if (appId && appId.length > 0 && appId.indexOf('http://') !== 0 && appId.indexOf('https://') !== 0) {
      return appId;
    }
    if (origin && origin.length > 0) {
      return origin;
    }
    const om: RegExpMatchArray | null = appId.match(/^https?:\/\/[^\/]+/);
    return om ? om[0] : appId;
  }

  private normalizeScope(scope: string): string {
    if (scope === 'top' || scope === 'region') {
      return scope;
    }
    return 'top';
  }

  private buildOwner(origin: string, appId: string, region: string, scope: string): BundleResourceOwner {
    const finalScope: string = this.normalizeScope(scope);
    return {
      bundleKey: this.bundleKeyFor(origin, appId),
      bundleId: appId && appId.length > 0 ? appId : origin,
      origin: origin,
      region: region ? region : '',
      scope: finalScope,
      generation: finalScope === 'region' ? this.regionGeneration : 0
    };
  }

  private isOwnerCancelled(owner: BundleResourceOwner | undefined): boolean {
    if (!owner) {
      return false;
    }
    if (owner.scope === 'region') {
      if (owner.region.length > 0 && owner.region !== this.activeRegion) {
        return true;
      }
      if (owner.generation !== this.regionGeneration) {
        return true;
      }
    }
    return false;
  }

  private cancelRegionQueue(region: string): void {
    if (!region || region.length === 0 || this.bundleQueue.length === 0) {
      return;
    }
    const next: RawEntry[] = [];
    let removed: number = 0;
    for (let i = 0; i < this.bundleQueue.length; i++) {
      const entry: RawEntry = this.bundleQueue[i];
      const owner: BundleResourceOwner | undefined = this.bundleQueueOwners.get(entry.url);
      if (owner && owner.scope === 'region' && owner.region === region) {
        this.bundleQueueSources.delete(entry.url);
        this.bundleQueueOwners.delete(entry.url);
        removed++;
      } else {
        next.push(entry);
      }
    }
    this.bundleQueue = next;
    if (removed > 0) {
      hilog.info(DOMAIN, TAG, 'cancelRegionQueue %{public}s removed=%{public}d', region, removed);
    }
  }

  /** 查询某站离线包下载进度(无则返回 null)。参数可传 app id / origin / URL */
  getBundleProgress(idOrUrl: string): BundleProgress | null {
    const key: string = this.bundleKeyFor('', idOrUrl);
    const p: BundleProgressEntry | undefined = this.bundleProgress.get(key);
    if (p) {
      return { total: p.total, done: p.done };
    }
    let state: BundleState | undefined = this.bundleState.get(key);
    if (!state) {
      const om: RegExpMatchArray | null = idOrUrl.match(/^https?:\/\/[^\/]+/);
      const origin: string = om ? om[0] : '';
      if (origin.length > 0) {
        this.bundleState.forEach((v: BundleState) => {
          if (!state && v.origin === origin) {
            state = v;
          }
        });
      }
    }
    if (state && state.urls && state.urls.length > 0) {
      let done: number = 0;
      for (let i = 0; i < state.urls.length; i++) {
        const u: string = state.urls[i];
        if (this.diskIndex.has(u)) {
          done++;
        }
      }
      return { total: state.urls.length, done: done };
    }
    return null;
  }

  /** 查询某站离线包最近一次失败原因(无则返回空字符串) */
  getBundleError(origin: string): string {
    const err: string | undefined = this.bundleErrors.get(origin);
    return err ? err : '';
  }

  isBundleApplied(idOrUrl: string, bundleVersion: string = ''): boolean {
    const key: string = this.bundleKeyFor('', idOrUrl);
    let state: BundleState | undefined = this.bundleState.get(key);
    if (!state) {
      const om: RegExpMatchArray | null = idOrUrl.match(/^https?:\/\/[^\/]+/);
      const origin: string = om ? om[0] : '';
      if (origin.length > 0) {
        this.bundleState.forEach((v: BundleState) => {
          if (!state && v.origin === origin) {
            state = v;
          }
        });
      }
    }
    if (!state) {
      return false;
    }
    if (!state || !state.urls || state.urls.length === 0) {
      return false;
    }
    if (bundleVersion.length > 0 && state.version !== bundleVersion) {
      return false;
    }
    for (let i = 0; i < state.urls.length; i++) {
      const u: string = state.urls[i];
      if (!this.diskIndex.has(u)) {
        return false;
      }
    }
    return true;
  }

  /** 某资源下完后:若属于某站离线包,推进其完成计数 */
  private markBundleResource(cacheKey: string): void {
    this.bundleProgress.forEach((p: BundleProgressEntry) => {
      if (p.expected.has(cacheKey)) {
        p.expected.delete(cacheKey);
        p.done++;
      }
    });
  }

  /**
   * onInterceptRequest 的同步入口。
   * @returns 命中返回本地 WebResourceResponse;否则 null(走网络)
   */
  intercept(url: string, method: string, _headers: Array<Header>): WebResourceResponse | null {
    if (!this.ready) {
      return null;
    }
    url = this.normalizeRequestUrl(url);
    if (url.length === 0) {
      return null;
    }

    if (this.isBlocked(url)) {
      this.blocked++;
      return this.emptyResponse(url);
    }

    const m: string = method && method.length > 0 ? method.toUpperCase() : 'GET';
    if (m !== 'GET') {
      return null;
    }

    const hit: SchemeHit | null = this.readSchemeHit(url);
    if (!hit) {
      this.miss++;
      return null;
    }
    return this.buildResponse(hit.body, hit.mime);
  }

  /**
   * 给外部 WebView 容器使用的 SchemeHandler 接入口。
   * 命中离线包时直接向 WebResourceHandler 写响应;未命中返回 false,由宿主继续放行网络。
   */
  handleSchemeRequest(request: webview.WebSchemeHandlerRequest, handler: webview.WebResourceHandler): boolean {
    if (!this.ready || !request || !handler) {
      return false;
    }
    const url: string = request.getRequestUrl();
    const method: string = request.getRequestMethod();
    const m: string = method && method.length > 0 ? method.toUpperCase() : 'GET';
    if (m !== 'GET') {
      return false;
    }
    const hit: SchemeHit | null = this.readSchemeHit(url);
    if (!hit) {
      return false;
    }
    try {
      const response = new webview.WebSchemeHandlerResponse();
      response.setNetErrorCode(WebNetErrorList.NET_OK);
      response.setStatus(200);
      response.setStatusText('OK');
      response.setMimeType(hit.mime);
      response.setEncoding('utf-8');
      handler.didReceiveResponse(response);
      handler.didReceiveResponseBody(hit.body);
      handler.didFinish();
      hilog.info(DOMAIN, TAG, 'offline HIT %{public}s mime=%{public}s bytes=%{public}d',
        url, hit.mime, hit.body.byteLength);
      return true;
    } catch (e) {
      const er = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'scheme response failed %{public}s', er.message);
      return false;
    }
  }

  private readSchemeHit(url: string): SchemeHit | null {
    if (!url || url.length === 0) {
      return null;
    }
    const cacheKey: string = this.normalizeRequestUrl(url);
    const disk: DiskEntry | undefined = this.diskIndex.get(cacheKey);
    if (disk) {
      if (disk.source !== 'bundle') {
        this.removeCached(cacheKey);
        this.saveDiskIndex();
        return null;
      }
      if (disk.encoding && disk.encoding.length > 0) {
        const decoded: ArrayBuffer | undefined = this.decodedMemory.get(cacheKey);
        if (decoded !== undefined) {
          disk.atime = Date.now();
          this.hitDisk++;
          return { body: decoded, mime: disk.mime };
        }
        this.warmDecodedEntry(cacheKey, disk);
        return null;
      }
      const buf: ArrayBuffer | null = this.readFile(this.cacheDir + '/' + disk.file);
      if (buf) {
        disk.atime = Date.now();
        this.hitDisk++;
        return { body: buf, mime: disk.mime };
      }
      this.removeCached(cacheKey);
      this.saveDiskIndex();
      this.reportBundleCorruptIfNeeded(cacheKey);
      return null;
    }
    return null;
  }

  /** Normalize URL exactly as the backend manifest does. */
  private normalizeRequestUrl(input: string): string {
    let out: string = input ? input.trim() : '';
    if (out.length === 0) {
      return '';
    }
    const hash: number = out.indexOf('#');
    if (hash >= 0) {
      out = out.substring(0, hash);
    }
    const scheme: number = out.indexOf('://');
    if (scheme > 0) {
      const hostStart: number = scheme + 3;
      const pathStart: number = out.indexOf('/', hostStart);
      const queryStart: number = out.indexOf('?', hostStart);
      if (pathStart < 0 || (queryStart >= 0 && queryStart < pathStart)) {
        if (queryStart >= 0) {
          out = out.substring(0, queryStart) + '/' + out.substring(queryStart);
        } else {
          out = out + '/';
        }
      }
    }
    return out;
  }

  shouldDropUnbundledRequest(url: string, method: string): boolean {
    const m: string = method && method.length > 0 ? method.toUpperCase() : 'GET';
    if (m !== 'GET') {
      return false;
    }
    const normalized: string = this.normalizeRequestUrl(url);
    if (normalized.length === 0 || this.hasOfflineResource(normalized)) {
      return false;
    }
    const origin: string = this.originFromUrl(normalized);
    if (origin.length === 0 || !this.bundleAppByOrigin.has(origin)) {
      return false;
    }
    const state: BundleState | undefined = this.bundleStateForOrigin(origin);
    if (!state || !state.urls || state.urls.length === 0) {
      return false;
    }
    if (this.bundleStateHasUrl(state, normalized)) {
      return false;
    }
    return this.isStrictStaticRequest(normalized);
  }

  dropResponse(url: string): WebResourceResponse {
    return this.emptyResponse(this.normalizeRequestUrl(url));
  }

  private hasOfflineResource(url: string): boolean {
    return this.diskIndex.has(url);
  }

  private bundleStateForOrigin(origin: string): BundleState | undefined {
    let state: BundleState | undefined = undefined;
    this.bundleState.forEach((v: BundleState) => {
      if (!state && v.origin === origin) {
        state = v;
      }
    });
    return state;
  }

  private bundleStateHasUrl(state: BundleState, url: string): boolean {
    for (let i = 0; i < state.urls.length; i++) {
      if (this.normalizeRequestUrl(state.urls[i]) === url) {
        return true;
      }
    }
    return false;
  }

  private isStrictStaticRequest(url: string): boolean {
    if (url.indexOf('/_next/static/') >= 0 || url.indexOf('/_next/image?') >= 0) {
      return true;
    }
    const q: number = url.indexOf('?');
    const path: string = (q >= 0 ? url.substring(0, q) : url).toLowerCase();
    return path.endsWith('.js') || path.endsWith('.mjs') || path.endsWith('.css') ||
      path.endsWith('.woff') || path.endsWith('.woff2') || path.endsWith('.ttf') ||
      path.endsWith('.otf') || path.endsWith('.eot') || path.endsWith('.png') ||
      path.endsWith('.jpg') || path.endsWith('.jpeg') || path.endsWith('.webp') ||
      path.endsWith('.avif') || path.endsWith('.gif') || path.endsWith('.svg') ||
      path.endsWith('.ico');
  }

  /** 调试统计快照 */
  stats(): CacheStats {
    return {
      raw: 0,
      disk: this.diskIndex.size,
      hitRaw: 0,
      hitDisk: this.hitDisk,
      miss: this.miss,
      blocked: this.blocked,
      bytes: this.totalBytes,
      inflight: this.inflight.size,
      pending: 0,
      bundleActive: this.activeBundleDownloads,
      bundleQueued: this.bundleQueue.length,
      lastUrl: this.lastCachedUrl,
      recent: this.recentCached.slice(0),
      caching: this.lastCacheAt > 0 && (Date.now() - this.lastCacheAt) < 3000
    };
  }

  /** 是否命中黑名单(会挂死的外部请求) */
  private isBlocked(url: string): boolean {
    // 用"全局 + 该应用额外"的合并黑名单(按 origin);无应用匹配时退回全局
    const hosts: string[] = this.blockListFor(url);
    for (let i = 0; i < hosts.length; i++) {
      if (url.indexOf(hosts[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 构造一个立即就绪的空响应,让被拦的请求瞬间结束而不是挂起 */
  private emptyResponse(url: string): WebResourceResponse {
    const resp: WebResourceResponse = new WebResourceResponse();
    let mime: string = 'text/plain';
    if (url.indexOf('.css') >= 0 || url.indexOf('/css') >= 0 || url.indexOf('fonts.googleapis') >= 0) {
      mime = 'text/css'; // 字体/样式端点(如 fonts.googleapis.com/css2)→ 空 CSS,降级系统字体
    } else if (url.indexOf('.js') >= 0 || url.indexOf('gtag') >= 0 || url.indexOf('analytics') >= 0) {
      mime = 'application/javascript';
    }
    resp.setResponseData(' '); // 非空但无意义,避免某些内核对空体的处理差异
    resp.setResponseEncoding('utf-8');
    resp.setResponseMimeType(mime);
    resp.setResponseCode(200);
    resp.setReasonMessage('OK');
    resp.setResponseHeader([
      { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
      { headerKey: 'X-Offline-Cache', headerValue: 'DROP' }
    ]);
    resp.setResponseIsReady(true);
    return resp;
  }

  // ——————————————————— 内部实现 ———————————————————

  private buildResponse(buf: ArrayBuffer, mime: string): WebResourceResponse {
    const resp: WebResourceResponse = new WebResourceResponse();
    resp.setResponseData(buf);
    resp.setResponseMimeType(mime);
    resp.setResponseEncoding('utf-8');
    resp.setResponseCode(200);
    resp.setReasonMessage('OK');
    const headers: Array<Header> = [
      { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
      { headerKey: 'Cache-Control', headerValue: 'max-age=31536000' },
      { headerKey: 'X-Offline-Cache', headerValue: 'HIT' }
    ];
    resp.setResponseHeader(headers);
    resp.setResponseIsReady(true);
    return resp;
  }

  /** Download one manifest resource and store it under the original website URL. */
  private fetchAndStore(cacheKey: string, sourceUrl: string, mime: string,
    onDone: (ok: boolean) => void, contentEncoding: string,
    rawSize: number, owner?: BundleResourceOwner): void {
    if (this.isOwnerCancelled(owner)) {
      if (onDone) {
        onDone(false);
      }
      return;
    }
    if (this.inflight.has(cacheKey)) {
      onDone(false);
      return;
    }
    if (this.diskIndex.has(cacheKey)) {
      onDone(true);
      return;
    }
    this.inflight.add(cacheKey);
    // 调试浮窗:一发起下载就记录"正在缓存的资源"(不等下完),并入最近列表(新→旧,留 12 条)
    this.lastCachedUrl = cacheKey;
    if (this.recentCached.length === 0 || this.recentCached[0] !== cacheKey) {
      this.recentCached.unshift(cacheKey);
      if (this.recentCached.length > 12) {
        this.recentCached.pop();
      }
    }
    const client = http.createHttp();
    const reqHeader: Record<string, string> = {
      'Accept': 'text/html,image/avif,image/webp,application/javascript,text/css,*/*',
      'Accept-Encoding': 'identity' // 关键:拿未压缩的真实字节,直接可服务,避免 gzip 误存
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      header: reqHeader,
      connectTimeout: 15000,
      readTimeout: 30000
    };
    client.request(sourceUrl, options, (err: BusinessError, data: http.HttpResponse) => {
      this.inflight.delete(cacheKey);
      let ok: boolean = false;
      try {
        if (this.isOwnerCancelled(owner)) {
          ok = false;
        } else if (!err && data && data.responseCode === 200 && data.result instanceof ArrayBuffer) {
          const body: ArrayBuffer = data.result as ArrayBuffer;
          const file: string = this.fileNameFor(cacheKey);
          const finalMime: string = mime.length > 0 ? mime : this.pickMime(cacheKey, data.header);
          this.writeBinary(this.cacheDir + '/' + file, body);
          const now: number = Date.now();
          const entry: DiskEntry = {
            url: cacheKey, file: file, mime: finalMime, size: body.byteLength,
            atime: now, storedAt: now, version: '', source: 'bundle',
            encoding: contentEncoding.length > 0 ? contentEncoding : undefined,
            rawSize: rawSize > 0 ? rawSize : undefined,
            bundleId: owner && owner.bundleId.length > 0 ? owner.bundleId : undefined,
            region: owner && owner.region.length > 0 ? owner.region : undefined,
            scope: owner && owner.scope.length > 0 ? owner.scope : undefined
          };
          this.diskIndex.set(cacheKey, entry);
          this.totalBytes += body.byteLength;
          this.evictIfNeeded();
          this.saveDiskIndex();
          if (entry.encoding) {
            this.warmDecodedEntry(cacheKey, entry);
          }
          this.markBundleResource(cacheKey);
          this.lastCacheAt = now;
          ok = true;
          hilog.info(DOMAIN, TAG, 'bundle STORE %{public}d B %{public}s', body.byteLength, cacheKey);
        }
      } catch (e) {
        const er = e as BusinessError;
        hilog.error(DOMAIN, TAG, 'store failed: %{public}s', er.message);
      }
      client.destroy();
      onDone(ok);
    });
  }

  /** 远程离线包下载任务入队,用有限并发避免抢占首屏主链路 */
  private enqueueBundleDownload(entry: RawEntry, sourceUrl: string, owner: BundleResourceOwner): void {
    if (this.isOwnerCancelled(owner)) {
      return;
    }
    if (this.diskIndex.has(entry.url) || this.inflight.has(entry.url) ||
      this.bundleQueueSources.has(entry.url)) {
      return;
    }
    this.bundleQueue.push(entry);
    this.bundleQueueSources.set(entry.url, sourceUrl);
    this.bundleQueueOwners.set(entry.url, owner);
    hilog.info(DOMAIN, TAG, 'bundle enqueue key=%{public}s id=%{public}s region=%{public}s scope=%{public}s url=%{public}s source=%{public}s queued=%{public}d active=%{public}d',
      owner.bundleKey, owner.bundleId,
      owner.region.length > 0 ? owner.region : '(none)', owner.scope,
      entry.url, sourceUrl, this.bundleQueue.length, this.activeBundleDownloads);
    this.pumpBundleQueue();
  }

  private pumpBundleQueue(): void {
    while (this.activeBundleDownloads < this.bundleConcurrency && this.bundleQueue.length > 0) {
      const entry: RawEntry | undefined = this.bundleQueue.shift();
      if (!entry) {
        return;
      }
      const src: string | undefined = this.bundleQueueSources.get(entry.url);
      const owner: BundleResourceOwner | undefined = this.bundleQueueOwners.get(entry.url);
      this.bundleQueueSources.delete(entry.url);
      this.bundleQueueOwners.delete(entry.url);
      if (!src || src.length === 0) {
        continue;
      }
      if (this.isOwnerCancelled(owner)) {
        continue;
      }
      if (this.diskIndex.has(entry.url)) {
        this.markBundleResource(entry.url);
        continue;
      }
      this.activeBundleDownloads++;
      const rawSize: number = entry.rawSize && entry.rawSize > 0 ? entry.rawSize : 0;
      this.fetchAndStore(entry.url, src, entry.mime, (_ok: boolean) => {
        this.activeBundleDownloads--;
        this.pumpBundleQueue();
      }, entry.encoding ? entry.encoding : '', rawSize, owner);
    }
  }

  /**
   * 远程离线包:从后台 manifest 把该站资源下载进沙箱(缓存 key = 原站 URL)。
   * 这是"App 缓存去服务器下载"的核心入口,替代打进 HAP 的内置包。
   * @param siteUrl     站点任意 URL(取 origin,完成后通知补注入字节码)
   * @param manifestUrl 后台 manifest 全地址(如 http://server:8787/bundles/<id>/manifest.json)
   */
  async loadRemoteBundle(siteUrl: string, manifestUrl: string, bundleVersion: string = '',
    appId: string = '', region: string = '', scope: string = 'app', configJson: string = ''): Promise<void> {
    const om = siteUrl.match(/^https?:\/\/[^\/]+/);
    const origin: string = om ? om[0] : '';
    if (origin.length === 0 || manifestUrl.length === 0) {
      return;
    }
    const owner: BundleResourceOwner = this.buildOwner(origin, appId, region, scope);
    if (this.isOwnerCancelled(owner)) {
      hilog.info(DOMAIN, TAG, 'bundle request canceled key=%{public}s id=%{public}s origin=%{public}s region=%{public}s scope=%{public}s',
        owner.bundleKey, owner.bundleId, owner.origin,
        owner.region.length > 0 ? owner.region : '(none)', owner.scope);
      return;
    }
    const bundleKey: string = owner.bundleKey;
    hilog.info(DOMAIN, TAG, 'bundle request key=%{public}s id=%{public}s origin=%{public}s region=%{public}s scope=%{public}s ver=%{public}s manifest=%{public}s configJsonBytes=%{public}d',
      bundleKey, owner.bundleId, origin,
      owner.region.length > 0 ? owner.region : '(none)', owner.scope,
      bundleVersion.length > 0 ? bundleVersion : '(none)', manifestUrl, configJson.length);
    // 版本门:已应用版本 == 当前下发版本 → 离线包无变化,直接用本地(连清单都不拉)
    const applied: BundleState | undefined = this.bundleState.get(bundleKey);
    if (bundleVersion.length > 0 && applied !== undefined && applied.version === bundleVersion) {
      this.updateAppliedConfigJsonIfChanged(bundleKey, applied, configJson);
      this.warmCompressedDiskEntriesForUrls(applied.urls);
      hilog.info(DOMAIN, TAG, 'bundle already applied key=%{public}s id=%{public}s origin=%{public}s region=%{public}s scope=%{public}s ver=%{public}s urls=%{public}d configJsonBytes=%{public}d',
        bundleKey,
        applied.id && applied.id.length > 0 ? applied.id : owner.bundleId,
        applied.origin && applied.origin.length > 0 ? applied.origin : origin,
        applied.region && applied.region.length > 0 ? applied.region : '(none)',
        applied.scope && applied.scope.length > 0 ? applied.scope : owner.scope,
        bundleVersion, applied.urls.length,
        applied.configJson && applied.configJson.length > 0 ? applied.configJson.length : 0);
      return;
    }
    if (this.loadedBundles.has(bundleKey)) {
      if (applied !== undefined) {
        this.warmCompressedDiskEntriesForUrls(applied.urls);
      }
      if (bundleVersion.length > 0) {
        const current: BundleState | undefined = this.bundleState.get(bundleKey);
        if (current !== undefined && current.version !== bundleVersion) {
          this.loadedBundles.delete(bundleKey);
          hilog.info(DOMAIN, TAG, 'bundle version changed in same session key=%{public}s old=%{public}s new=%{public}s, reload manifest',
            bundleKey, current.version.length > 0 ? current.version : '(none)', bundleVersion);
        } else if (current === undefined) {
          this.pendingBundleVersionByKey.set(bundleKey, bundleVersion);
          hilog.info(DOMAIN, TAG, 'bundle version pending until current download completes: %{public}s', bundleVersion);
          return;
        } else {
          this.updateAppliedConfigJsonIfChanged(bundleKey, current, configJson);
          return;
        }
      } else {
        if (applied !== undefined) {
          this.updateAppliedConfigJsonIfChanged(bundleKey, applied, configJson);
        }
        return;
      }
    }
    this.loadedBundles.add(bundleKey);
    this.bundleErrors.delete(bundleKey);
    const base: string = manifestUrl.replace(/\/manifest(?:\.[A-Za-z0-9_-]+)?\.json.*$/, ''); // 后台资源目录
    const txt: string = await this.httpGetText(manifestUrl);
    if (txt.length === 0) {
      hilog.warn(DOMAIN, TAG, 'remote bundle manifest unreachable: %{public}s', manifestUrl);
      this.bundleErrors.set(bundleKey, 'manifest不可达');
      this.loadedBundles.delete(bundleKey);
      return;
    }
    let arr: RawEntry[] = [];
    let manifestConfigJson: string = '';
    try {
      const parsed: Object = JSON.parse(txt) as Object;
      if (Array.isArray(parsed)) {
        arr = parsed as RawEntry[];
      } else {
        const obj = parsed as RemoteManifestObject;
        manifestConfigJson = obj.configJson && obj.configJson.length > 0
          ? obj.configJson
          : (obj.webConfigJson && obj.webConfigJson.length > 0 ? obj.webConfigJson : '');
        if (obj.resources && Array.isArray(obj.resources)) {
          arr = obj.resources;
        } else if (obj.manifest && Array.isArray(obj.manifest)) {
          arr = obj.manifest;
        }
      }
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'remote manifest parse failed: %{public}s', er.message);
      this.bundleErrors.set(bundleKey, 'manifest解析失败');
      this.loadedBundles.delete(bundleKey);
      return;
    }
    hilog.info(DOMAIN, TAG, 'bundle manifest parsed key=%{public}s id=%{public}s resources=%{public}d manifestConfigJsonBytes=%{public}d manifest=%{public}s',
      bundleKey, owner.bundleId, arr.length, manifestConfigJson.length, manifestUrl);
    let total: number = 0;
    let done: number = 0;
    const expected: Set<string> = new Set();
    const newUrls: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      const e: RawEntry = arr[i];
      if (!e || !e.url || !e.file) {
        continue;
      }
      // HTML must be explicitly marked by the backend; dynamic documents stay on the network.
      if (e.mime === 'text/html' && e.doc !== true) {
        continue;
      }
      total++;
      newUrls.push(e.url);
      const diskExisting: DiskEntry | undefined = this.diskIndex.get(e.url);
      if (diskExisting !== undefined) {
        const wantEncoding: string = e.encoding && e.encoding.length > 0 ? e.encoding : '';
        const haveEncoding: string = diskExisting.encoding && diskExisting.encoding.length > 0 ? diskExisting.encoding : '';
        const wantRawSize: number = e.rawSize && e.rawSize > 0 ? e.rawSize : 0;
        const wantSize: number = e.size && e.size > 0 ? e.size : 0;
        if (wantEncoding !== haveEncoding ||
          (wantRawSize > 0 && diskExisting.rawSize !== wantRawSize) ||
          (wantSize > 0 && diskExisting.size !== wantSize)) {
          this.removeCached(e.url);
        } else {
          if (haveEncoding.length > 0) {
            this.warmDecodedEntry(e.url, diskExisting);
          }
          done++;
          continue;
        }
      }
      expected.add(e.url);
      this.enqueueBundleDownload(e, base + '/' + e.file, owner); // 来源=后台文件,缓存 key=原站 URL
    }
    // 清理:上次清单里有、这次没有的资源 → 删本地(服务端移除/换名后去陈旧)
    if (applied !== undefined && applied.urls.length > 0) {
      const keep: Set<string> = new Set<string>(newUrls);
      let removed: number = 0;
      for (let i = 0; i < applied.urls.length; i++) {
        const u: string = applied.urls[i];
        if (!keep.has(u)) {
          this.removeCached(u);
          removed++;
        }
      }
      if (removed > 0) {
        this.saveDiskIndex();
        hilog.info(DOMAIN, TAG, 'bundle cleanup removed %{public}d stale', removed);
      }
    }
    // 记录已应用版本 + URL 清单(下次开机版本门据此判断要不要更新)
    const pendingVersion: string | undefined = this.pendingBundleVersionByKey.get(bundleKey);
    const effectiveVersion: string = bundleVersion.length > 0 ? bundleVersion : (pendingVersion !== undefined ? pendingVersion : '');
    this.pendingBundleVersionByKey.delete(bundleKey);
    const finalConfigJson: string = manifestConfigJson.length > 0 ? manifestConfigJson : configJson;
    this.bundleState.set(bundleKey, {
      key: bundleKey,
      id: owner.bundleId,
      origin: origin,
      region: owner.region,
      scope: owner.scope,
      version: effectiveVersion,
      urls: newUrls,
      configJson: finalConfigJson.length > 0 ? finalConfigJson : undefined
    });
    this.saveBundleState();
    const prog: BundleProgressEntry = { total: total, done: done, expected: expected };
    this.bundleProgress.set(bundleKey, prog);
    this.bundleProgress.set(origin, prog);
    this.bundleErrors.delete(bundleKey);
    hilog.info(DOMAIN, TAG, 'remote bundle: total %{public}d, to download %{public}d, ver %{public}s',
      total, total - done, effectiveVersion.length > 0 ? effectiveVersion : '(none)');
    hilog.info(DOMAIN, TAG, 'bundle state saved key=%{public}s id=%{public}s origin=%{public}s region=%{public}s scope=%{public}s ver=%{public}s urls=%{public}d download=%{public}d configJsonBytes=%{public}d',
      bundleKey, owner.bundleId, origin,
      owner.region.length > 0 ? owner.region : '(none)', owner.scope,
      effectiveVersion.length > 0 ? effectiveVersion : '(none)', newUrls.length, total - done,
      finalConfigJson.length);
  }

  private httpGetText(url: string): Promise<string> {
    return new Promise<string>((resolve) => {
      const client = http.createHttp();
      const header: Record<string, string> = { 'Accept': 'application/json,text/plain,*/*' };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        header: header,
        connectTimeout: 15000,
        readTimeout: 30000
      };
      client.request(url, options, (err: BusinessError, data: http.HttpResponse) => {
        let out: string = '';
        if (!err && data && data.responseCode === 200 && typeof data.result === 'string') {
          out = data.result as string;
        }
        client.destroy();
        resolve(out);
      });
    });
  }

  private updateAppliedConfigJsonIfChanged(bundleKey: string, state: BundleState, configJson: string): void {
    if (!configJson || configJson.length === 0) {
      return;
    }
    const oldConfig: string = state.configJson && state.configJson.length > 0 ? state.configJson : '';
    if (oldConfig === configJson) {
      return;
    }
    state.configJson = configJson;
    this.bundleState.set(bundleKey, state);
    this.saveBundleState();
    hilog.info(DOMAIN, TAG, 'bundle configJson refreshed key=%{public}s origin=%{public}s bytes=%{public}d',
      bundleKey,
      state.origin && state.origin.length > 0 ? state.origin : '(none)',
      configJson.length);
  }

  /** 超过容量上限时按 LRU(最久未访问)逐个淘汰 */
  private evictIfNeeded(): void {
    while (this.totalBytes > this.diskCapBytes && this.diskIndex.size > 0) {
      let oldestUrl: string = '';
      let oldestAt: number = Number.MAX_SAFE_INTEGER;
      this.diskIndex.forEach((v: DiskEntry, k: string) => {
        if (v.atime < oldestAt) {
          oldestAt = v.atime;
          oldestUrl = k;
        }
      });
      if (oldestUrl.length === 0) {
        break;
      }
      const victim: DiskEntry | undefined = this.diskIndex.get(oldestUrl);
      if (victim) {
        this.removeFile(this.cacheDir + '/' + victim.file);
        this.totalBytes -= victim.size;
        this.diskIndex.delete(oldestUrl);
        this.decodedMemory.delete(oldestUrl);
        this.decoding.delete(oldestUrl);
        hilog.info(DOMAIN, TAG, 'evict %{public}s', victim.file);
      }
    }
  }

  private pickMime(url: string, header: Object): string {
    let ct: string = '';
    const h = header as Record<string, string>;
    if (h) {
      const a: string = h['content-type'];
      const b: string = h['Content-Type'];
      ct = a ? a : (b ? b : '');
    }
    if (ct && ct.length > 0) {
      return ct.split(';')[0].trim();
    }
    if (url.indexOf('/_next/image') >= 0) {
      return 'image/webp';
    }
    if (url.indexOf('.css') >= 0) {
      return 'text/css';
    }
    if (url.indexOf('.js') >= 0) {
      return 'application/javascript';
    }
    if (url.indexOf('.woff2') >= 0) {
      return 'font/woff2';
    }
    if (url.indexOf('.woff') >= 0) {
      return 'font/woff';
    }
    if (url.indexOf('.ttf') >= 0) {
      return 'font/ttf';
    }
    return 'application/octet-stream';
  }

  private readFile(path: string): ArrayBuffer | null {
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
      const size: number = fs.statSync(path).size;
      const buf: ArrayBuffer = new ArrayBuffer(size);
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      return buf;
    } catch (e) {
      return null;
    }
  }

  private writeBinary(path: string, buf: ArrayBuffer): void {
    try {
      const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, buf);
      fs.closeSync(f);
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'writeBinary failed: %{public}s', er.message);
    }
  }

  private warmCompressedDiskEntriesForUrls(urls: string[]): void {
    if (!urls || urls.length === 0) {
      return;
    }
    for (let i = 0; i < urls.length; i++) {
      const url: string = urls[i];
      const entry: DiskEntry | undefined = this.diskIndex.get(url);
      if (entry && entry.encoding && entry.encoding.length > 0) {
        this.warmDecodedEntry(url, entry);
      }
    }
  }

  private warmDecodedEntry(url: string, entry: DiskEntry): void {
    if (!entry.encoding || entry.encoding.length === 0) {
      return;
    }
    if (entry.encoding !== 'zlib') {
      hilog.warn(DOMAIN, TAG, 'unsupported compressed cache %{public}s %{public}s', entry.encoding, url);
      return;
    }
    if (this.decodedMemory.has(url) || this.decoding.has(url)) {
      return;
    }
    const rawSize: number = entry.rawSize && entry.rawSize > 0 ? entry.rawSize : 0;
    if (rawSize <= 0) {
      hilog.warn(DOMAIN, TAG, 'compressed cache missing rawSize %{public}s', url);
      return;
    }
    const packed: ArrayBuffer | null = this.readFile(this.cacheDir + '/' + entry.file);
    if (!packed) {
      return;
    }
    this.decoding.add(url);
    const out: ArrayBuffer = new ArrayBuffer(rawSize);
    const zip: zlib.Zip = zlib.createZipSync();
    zip.uncompress(out, packed, packed.byteLength)
      .then((info: zlib.ZipOutputInfo) => {
        const len: number = info.destLen > 0 && info.destLen <= out.byteLength ? info.destLen : out.byteLength;
        const decoded: ArrayBuffer = len === out.byteLength ? out : out.slice(0, len);
        this.decodedMemory.set(url, decoded);
        this.decoding.delete(url);
        hilog.info(DOMAIN, TAG, 'cache DECODE %{public}s %{public}d -> %{public}d B %{public}s',
          entry.encoding as string, packed.byteLength, decoded.byteLength, url);
      })
      .catch((e: BusinessError) => {
        this.decoding.delete(url);
        hilog.warn(DOMAIN, TAG, 'cache DECODE failed %{public}s: %{public}s', url, e.message);
      });
  }

  private removeFile(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      // 忽略:文件可能已不存在
    }
  }

  private loadDiskIndex(): void {
    try {
      if (!fs.accessSync(this.indexPath)) {
        return;
      }
      const size: number = fs.statSync(this.indexPath).size;
      const buf: ArrayBuffer = new ArrayBuffer(size);
      const f = fs.openSync(this.indexPath, fs.OpenMode.READ_ONLY);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      const txt: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
      if (txt && txt.length > 0) {
        const arr = JSON.parse(txt) as DiskEntry[];
        for (let i = 0; i < arr.length; i++) {
          const e: DiskEntry = arr[i];
          if (!e.version) {
            e.version = ''; // 兼容旧索引(无 version 字段)
          }
          this.diskIndex.set(e.url, e);
          this.totalBytes += e.size;
        }
      }
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'loadDiskIndex failed: %{public}s', er.message);
    }
  }

  private saveDiskIndex(): void {
    try {
      const arr: DiskEntry[] = [];
      this.diskIndex.forEach((v: DiskEntry) => {
        arr.push(v);
      });
      const txt: string = JSON.stringify(arr);
      const f = fs.openSync(this.indexPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, txt);
      fs.closeSync(f);
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'saveDiskIndex failed: %{public}s', er.message);
    }
  }

  /** 删除一条沙箱缓存(文件 + 索引 + 体积),用于离线包更新时清理被移除的旧资源 */
  private removeCached(url: string): void {
    const e: DiskEntry | undefined = this.diskIndex.get(url);
    if (e !== undefined) {
      this.removeFile(this.cacheDir + '/' + e.file);
      this.totalBytes -= e.size;
      this.diskIndex.delete(url);
      this.decodedMemory.delete(url);
      this.decoding.delete(url);
    }
  }

  /** 读取离线包已应用状态(版本门 + 清理用) */
  private loadBundleState(): void {
    try {
      if (!fs.accessSync(this.bundleStatePath)) {
        return;
      }
      const size: number = fs.statSync(this.bundleStatePath).size;
      const buf: ArrayBuffer = new ArrayBuffer(size);
      const f = fs.openSync(this.bundleStatePath, fs.OpenMode.READ_ONLY);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      const txt: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
      if (txt && txt.length > 0) {
        const arr = JSON.parse(txt) as BundleState[];
        for (let i = 0; i < arr.length; i++) {
          const s: BundleState = arr[i];
          if (s && s.origin) {
            const key: string = s.key && s.key.length > 0 ? s.key : (s.id && s.id.length > 0 ? s.id : s.origin);
            this.bundleState.set(key, {
              key: key,
              id: s.id ? s.id : '',
              origin: s.origin,
              region: s.region ? s.region : '',
              scope: s.scope ? s.scope : '',
              version: s.version ? s.version : '',
              urls: s.urls ? s.urls : [],
              configJson: s.configJson ? s.configJson : undefined
            });
          }
        }
      }
    } catch (e) {
      // 忽略:首次无文件
    }
  }

  private saveBundleState(): void {
    try {
      const arr: BundleState[] = [];
      this.bundleState.forEach((v: BundleState) => {
        arr.push(v);
      });
      const txt: string = JSON.stringify(arr);
      const f = fs.openSync(this.bundleStatePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, txt);
      fs.closeSync(f);
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'saveBundleState failed: %{public}s', er.message);
    }
  }

  /**
   * 离线包资源实际读不出(文件丢/坏)→ 上报后台自愈重建该站离线包。
   * 仅当该 URL 属于某 bundle:true 站时才报;本会话每站只报一次,避免刷请求。
   * 全程 fire-and-forget,不阻塞 intercept 热路径,上报失败也不影响用户(端侧已放行走网络兜底)。
   */
  private reportBundleCorruptIfNeeded(url: string): void {
    if (this.serverBase.length === 0) {
      return; // 无后端(纯本地/直供模式),不上报
    }
    const om: RegExpMatchArray | null = url.match(/^https?:\/\/[^\/]+/);
    const origin: string = om ? om[0] : '';
    if (origin.length === 0) {
      return;
    }
    const appId: string | undefined = this.bundleAppByOrigin.get(origin);
    if (appId === undefined || appId.length === 0) {
      return; // 不是离线包站的资源,无需自愈
    }
    if (this.reportedSelfHeal.has(appId)) {
      return; // 本会话已为该站报过,防刷
    }
    this.reportedSelfHeal.add(appId);
    const body: SelfHealBody = { appId: appId, reason: 'bundle-resource-missing' };
    const client = http.createHttp();
    const header: Record<string, string> = { 'Content-Type': 'application/json' };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: header,
      extraData: JSON.stringify(body),
      connectTimeout: 15000,
      readTimeout: 30000
    };
    client.request(this.serverBase + '/api/report-error', options, (err: BusinessError, data: http.HttpResponse) => {
      client.destroy();
      if (!err && data) {
        hilog.info(DOMAIN, TAG, 'self-heal report %{public}s code=%{public}d', appId, data.responseCode);
      } else {
        hilog.warn(DOMAIN, TAG, 'self-heal report failed %{public}s', appId);
      }
    });
  }

  /** 由完整 URL 生成文件系统安全的文件名(双 DJB2,够防碰撞) */
  private fileNameFor(url: string): string {
    let h1: number = 5381;
    let h2: number = 52711;
    for (let i = 0; i < url.length; i++) {
      const c: number = url.charCodeAt(i);
      h1 = ((h1 * 33) ^ c) >>> 0;
      h2 = ((h2 * 33) ^ c) >>> 0;
    }
    return (h1 >>> 0).toString(16).padStart(8, '0') + (h2 >>> 0).toString(16).padStart(8, '0') + '.bin';
  }
}

/** 全局单例 */
export const webCache: WebCacheManager = new WebCacheManager();
