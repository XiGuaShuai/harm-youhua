import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RemoteSettings, RemoteApp, StaticCachePolicy } from './RemoteConfig';

const TAG: string = 'WebCache';
const DOMAIN: number = 0x0001;
const RAW_DIR: string = 'webcache';                 // rawfile 下的目录
const DISK_CAP_BYTES: number = 160 * 1024 * 1024;   // 沙箱运行时缓存总量上限:按 200MB 沙箱预留余量
const DOC_CHECK_MS: number = 60 * 1000;             // 主文档版本校验节流:60 秒内不重复校验
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

/** 通用静态资源扩展名(用于识别可缓存的不可变资源) */
const STATIC_EXTS: Set<string> = new Set<string>([
  'js', 'mjs', 'css', 'woff', 'woff2', 'ttf', 'otf', 'eot',
  'png', 'jpg', 'jpeg', 'gif', 'svg', 'webp', 'avif', 'ico'
]);

/** 内置包(rawfile)索引,只读 */
interface RawEntry {
  url: string;
  file: string;
  mime: string;
  size?: number;
  encoding?: string; // zlib: local file is compressed; decode before serving to WebView
  rawSize?: number;  // 原始大小,仅用于统计/排查
}

/** 沙箱运行时缓存索引,可写,带 LRU 字段 */
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
}

/** 调试用统计 */
export interface CacheStats {
  raw: number;          // 内置包条数
  disk: number;         // 沙箱缓存条数
  hitRaw: number;       // 命中内置包次数
  hitDisk: number;      // 命中沙箱次数
  miss: number;         // 透传次数
  blocked: number;      // 短路掉的外部挂起请求次数
  bytes: number;        // 沙箱已用字节
  // —— 后台缓存活动(用于"是否在背后偷偷再缓存")——
  inflight: number;     // 正在下载回填的资源数
  pending: number;      // 页面加载完待回填的资源数
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
  origin: string;
  version: string; // 已应用的 bundleVersion(与 /api/config 下发的对比,一致则跳过更新)
  urls: string[];  // 已应用清单里的资源 URL(用于清理被服务端移除的旧资源)
}

/** 众包探索上报:一条资源 + 报文体 */
interface ReportItem {
  url: string;
  hash: string;   // = DiskEntry.version(djb2 指纹),服务端按它做跨用户共识
  mime: string;
  size: number;
}
interface ReportBody {
  appId: string;
  anonId: string;
  resources: ReportItem[];
}
/** 离线包资源损坏 → 后台自愈上报体 */
interface SelfHealBody {
  appId: string;
  reason: string;
}

/**
 * Web 离线缓存管理器(单例)。两层只读/可写缓存:
 *
 *   ① rawfile 内置包(发版时打进 App)——首次启动即命中,绕过 No-Store 的跨境慢链路;
 *   ② 沙箱运行时缓存(下载回填)——覆盖按需 chunk、以及站点 redeploy 后的新 hash,自愈;
 *   ③ 都没有 → 透传走网络。
 *
 * 只接管"内容 hash 命名、不可变"的 _next/static 与确定性的 _next/image;
 * hash 一变 URL 就变,永不发旧。动态 HTML / 接口 / 第三方一律透传。
 */
class WebCacheManager {
  private cacheDir: string = '';
  private indexPath: string = '';
  private resMgr: resourceManager.ResourceManager | null = null;

  // —— 以下三项默认值见文件顶部常量;接入后台后由 applySettings / setBlockHosts 远程注入覆盖 ——
  private blockHosts: string[] = BLOCK_HOSTS;       // 过滤黑名单(可远程下发)
  private diskCapBytes: number = DISK_CAP_BYTES;    // 沙箱缓存上限(可远程下发)
  private docCheckMs: number = DOC_CHECK_MS;        // 主文档校验节流(可远程下发)
  private bundleConcurrency: number = BUNDLE_CONCURRENCY; // 远程离线包下载并发(可远程下发)
  private prefetchEnabled: boolean = true;          // 是否预取全站 chunk(可远程下发)
  private staticCachePolicy: StaticCachePolicy = {}; // 全局运行时静态资源缓存策略
  private runtimePrefetchAllowed: boolean = false;  // 端侧运行时预取/自动缓存固定关闭，只允许后台离线包落盘
  // 每应用精细配置:按 origin 索引。mergedBlockByOrigin = 全局黑名单 + 该应用 extraBlockHosts(预算好,intercept 热路径直接查)
  private mergedBlockByOrigin: Map<string, string[]> = new Map();
  private prefetchByOrigin: Map<string, boolean> = new Map(); // 该应用的 prefetchChunks 覆盖值
  private uaByOrigin: Map<string, string> = new Map();        // 该应用的自定义 UA(覆盖默认手机化 UA;按 origin 索引)
  private staticPolicyByOrigin: Map<string, StaticCachePolicy> = new Map(); // 每应用静态资源缓存策略
  private bundleAppByOrigin: Map<string, string> = new Map(); // origin → appId(仅 bundle:true 的站):离线包资源丢失自愈上报用
  private reportedSelfHeal: Set<string> = new Set();          // 已上报过自愈的 appId(本次会话只报一次,防刷)
  private serverBase: string = '';                            // 后端地址(applyApps 时由 remoteConfig.getServer() 注入,自愈上报用)

  private rawIndex: Map<string, RawEntry> = new Map();
  private diskIndex: Map<string, DiskEntry> = new Map();
  private inflight: Set<string> = new Set();
  private pending: Set<string> = new Set();
  private bundleQueue: RawEntry[] = [];
  private bundleQueueSources: Map<string, string> = new Map();
  private activeBundleDownloads: number = 0;
  private totalBytes: number = 0;
  private ready: boolean = false;

  private hitRaw: number = 0;
  private hitDisk: number = 0;
  private miss: number = 0;
  private blocked: number = 0;
  private docUrls: Set<string> = new Set();                       // 走 SWR 的主文档 URL
  private docUpdateHandler: ((url: string) => void) | null = null; // 检测到主文档新版本时回调(页面刷新)
  private prefetchedOrigins: Set<string> = new Set();             // 已预取过全部 chunk 的站点
  private loadedBundles: Set<string> = new Set();                 // 本次会话已拉过远程离线包的站点(按 origin)
  private pendingBundleVersionByOrigin: Map<string, string> = new Map(); // 兜底配置先拉包、远程配置后到时暂存版本号
  private bundleProgress: Map<string, BundleProgressEntry> = new Map(); // 各站离线包下载进度(按 origin)
  private bundleState: Map<string, BundleState> = new Map();      // 各站离线包已应用状态(版本+URL清单,持久化,用于更新检查)
  private bundleStatePath: string = '';                           // bundle-state.json 路径
  private decodedMemory: Map<string, ArrayBuffer> = new Map();     // decoded compressed bundle bytes; memory only
  private decoding: Set<string> = new Set();                       // URLs currently being decoded
  private anonId: string = '';                                    // 匿名上报 id(持久化,无个人信息)
  private lastCachedUrl: string = '';                             // 最近被后台缓存的资源 URL(调试浮窗用)
  private recentCached: string[] = [];                            // 最近若干条后台缓存(新→旧,调试浮窗列表用)
  private lastCacheAt: number = 0;                                // 最近一次"缓存成功"的时刻(判断是否真的还在缓存)

  /** 启动时调用一次(EntryAbility.onCreate) */
  init(context: common.UIAbilityContext): void {
    try {
      this.resMgr = context.resourceManager;
      this.cacheDir = context.filesDir + '/webcache';
      this.indexPath = this.cacheDir + '/index.json';
      this.bundleStatePath = this.cacheDir + '/bundle-state.json';
      if (!fs.accessSync(this.cacheDir)) {
        fs.mkdirSync(this.cacheDir, true);
      }
      this.loadRawManifest();
      this.loadDiskIndex();
      this.loadBundleState();
      this.ready = true;
      hilog.info(DOMAIN, TAG, 'ready, raw=%{public}d disk=%{public}d bytes=%{public}d',
        this.rawIndex.size, this.diskIndex.size, this.totalBytes);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', err.message);
    }
  }

  /** 开启主文档的 SWR(陈旧即用)缓存。传入要缓存的文档 URL(通常是首页) */
  enableDocCache(urls: string[]): void {
    if (!urls || urls.length === 0) {
      return;
    }
    // 当前 SDK 只保留后台离线包能力，不再启用端侧主文档 SWR 缓存。
  }

  private prefetchedRouteOrigins: Set<string> = new Set();

  /**
   * 通用路由预取(任何站点适用,不依赖 webpack):对配置了 routes 的应用,开机预拉这些路由页的
   * 主文档进缓存 + 注册 SWR。点击二级页(如 K11 美食页 /zh-cn/taste/)时主文档已在本地,省去现拉主文档的时间。
   * 注:只缓主文档,二级页的动态数据(跨境 API)仍实时拉,框架管不了那部分。
   * @param origin 站点 origin(如 https://hk.k11.com)
   * @param routes 路由列表(如 ['/zh-cn','/zh-cn/shop/','/zh-cn/taste/'])
   */
  prefetchRoutes(origin: string, routes: string[]): void {
    if (!origin || origin.length === 0 || !routes || routes.length === 0) {
      return;
    }
    if (!this.runtimePrefetchAllowed) {
      return;
    }
    if (this.prefetchedRouteOrigins.has(origin)) {
      return; // 每站只预取一次
    }
    this.prefetchedRouteOrigins.add(origin);
    const urls: string[] = [];
    for (let i = 0; i < routes.length; i++) {
      let r: string = routes[i];
      if (!r || r.length === 0) {
        continue;
      }
      if (r.charAt(0) !== '/') {
        r = '/' + r;
      }
      urls.push(origin + r);
    }
    if (urls.length === 0) {
      return;
    }
    // 只预下载这些路由页引用的【静态资源】,不缓主文档(主文档可能是动态页/带会话状态,
    // 缓了会导致点进去拿到错误的旧版本 → error。动态页的 HTML 交给运行时正常加载,我们只把资源提前备好)。
    for (let i = 0; i < urls.length; i++) {
      const u: string = urls[i];
      this.prefetchRoutePage(u, origin);
    }
    hilog.info(DOMAIN, TAG, 'prefetchRoutes %{public}d for %{public}s', urls.length, origin);
  }

  /** 抓单个路由页 HTML 仅用于【解析它引用的静态资源】并预下载;不缓主文档本身 */
  private prefetchRoutePage(pageUrl: string, origin: string): void {
    // 只用 HTML 文本解析资源链接,不把主文档写入缓存(避免动态页缓存导致 error)
    this.httpGetText(pageUrl).then((html: string) => {
      if (!html || html.length === 0) {
        return;
      }
      // 解析 <script src> / <link href> / <img src> 引用的资源,取同源 + 可缓存的预下载
      const refs: string[] = [];
      const reSrc = /(?:src|href)\s*=\s*["']([^"']+)["']/gi;
      let m: RegExpExecArray | null = reSrc.exec(html);
      let guard: number = 0;
      while (m !== null && guard < 500) {
        refs.push(m[1]);
        m = reSrc.exec(html);
        guard++;
      }
      let queued: number = 0;
      for (let i = 0; i < refs.length; i++) {
        const abs: string = this.resolveUrl(refs[i], origin, pageUrl);
        if (abs.length === 0) {
          continue;
        }
        // 只预取同源 + 可缓存(hash/版本号 query)资源;跨域、动态接口、不可缓资源跳过
        if (abs.indexOf(origin) === 0 && this.shouldCache(abs) &&
          !this.diskIndex.has(abs) && !this.rawIndex.has(abs) && !this.inflight.has(abs)) {
          this.download(abs);
          queued++;
        }
      }
      if (queued > 0) {
        hilog.info(DOMAIN, TAG, 'prefetchRoutePage %{public}s queued %{public}d res', pageUrl, queued);
      }
    });
  }

  /** 把相对/绝对引用解析成完整 URL(失败返回空串) */
  private resolveUrl(ref: string, origin: string, base: string): string {
    if (!ref || ref.length === 0) {
      return '';
    }
    if (ref.indexOf('http://') === 0 || ref.indexOf('https://') === 0) {
      return ref;
    }
    if (ref.indexOf('//') === 0) {
      return 'https:' + ref;
    }
    if (ref.charAt(0) === '/') {
      return origin + ref;
    }
    if (ref.charAt(0) === '#' || ref.indexOf('data:') === 0 || ref.indexOf('javascript:') === 0) {
      return '';
    }
    // 相对路径:相对于 base 的目录
    const q: number = base.indexOf('?');
    const clean: string = q >= 0 ? base.substring(0, q) : base;
    const slash: number = clean.lastIndexOf('/');
    const dir: string = slash >= 0 ? clean.substring(0, slash + 1) : (origin + '/');
    return dir + ref;
  }

  /** 注册"主文档检测到新版本"的回调。展示页用它在站点更新时刷新 WebView,做到最快失效 */
  setDocUpdateHandler(cb: (url: string) => void): void {
    this.docUpdateHandler = cb;
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
   * 以及该应用的 prefetchChunks 覆盖值。intercept/预取时按当前请求的 origin 取用,做到每应用单独生效。
   * 必须在 setBlockHosts 之后调用(依赖全局黑名单做合并)。
   */
  applyApps(apps: RemoteApp[], server: string = ''): void {
    this.mergedBlockByOrigin.clear();
    this.prefetchByOrigin.clear();
    this.uaByOrigin.clear();
    this.staticPolicyByOrigin.clear();
    this.bundleAppByOrigin.clear();
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
      // 每应用 prefetchChunks 覆盖(只在显式下发布尔值时记录)
      if (typeof app.prefetchChunks === 'boolean') {
        this.prefetchByOrigin.set(origin, app.prefetchChunks);
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

  /** 合并全局 + 每应用静态资源缓存策略。数组类规则叠加,数值/开关由每应用覆盖全局 */
  private staticPolicyFor(url: string): StaticCachePolicy {
    const out: StaticCachePolicy = {};
    this.mergeStaticPolicy(out, this.staticCachePolicy);
    const om = url.match(/^https?:\/\/[^\/]+/);
    const origin: string = om ? om[0] : '';
    if (origin.length > 0) {
      const appPolicy: StaticCachePolicy | undefined = this.staticPolicyByOrigin.get(origin);
      if (appPolicy) {
        this.mergeStaticPolicy(out, appPolicy);
      }
    }
    return out;
  }

  private mergeStaticPolicy(dst: StaticCachePolicy, src: StaticCachePolicy): void {
    if (!src) {
      return;
    }
    if (typeof src.enabled === 'boolean') {
      dst.enabled = src.enabled;
    }
    if (typeof src.minSizeKB === 'number') {
      dst.minSizeKB = src.minSizeKB;
    }
    if (typeof src.minDurationMs === 'number') {
      dst.minDurationMs = src.minDurationMs;
    }
    if (typeof src.maxSizeKB === 'number') {
      dst.maxSizeKB = src.maxSizeKB;
    }
    if (src.include && src.include.length > 0) {
      const arr: string[] = dst.include ? dst.include.slice() : [];
      for (let i = 0; i < src.include.length; i++) {
        arr.push(src.include[i]);
      }
      dst.include = arr;
    }
    if (src.exclude && src.exclude.length > 0) {
      const arr: string[] = dst.exclude ? dst.exclude.slice() : [];
      for (let i = 0; i < src.exclude.length; i++) {
        arr.push(src.exclude[i]);
      }
      dst.exclude = arr;
    }
  }

  private matchesAnyPattern(url: string, patterns: string[] | undefined): boolean {
    if (!patterns || patterns.length === 0) {
      return false;
    }
    for (let i = 0; i < patterns.length; i++) {
      if (this.matchesPattern(url, patterns[i])) {
        return true;
      }
    }
    return false;
  }

  /** 子串匹配;带 * 时按通配分段匹配,便于后台填 *.cdn.com/*.js 这类规则 */
  private matchesPattern(url: string, pattern: string): boolean {
    if (!pattern || pattern.length === 0) {
      return false;
    }
    const u: string = url.toLowerCase();
    const p: string = pattern.toLowerCase();
    if (p.indexOf('*') < 0) {
      return u.indexOf(p) >= 0;
    }
    const parts: string[] = p.split('*').filter((x: string) => x.length > 0);
    if (parts.length === 0) {
      return true;
    }
    if (p.charAt(0) !== '*' && u.indexOf(parts[0]) !== 0) {
      return false;
    }
    let pos: number = 0;
    for (let i = 0; i < parts.length; i++) {
      const idx: number = u.indexOf(parts[i], pos);
      if (idx < 0) {
        return false;
      }
      pos = idx + parts[i].length;
    }
    const last: string = parts[parts.length - 1];
    if (p.charAt(p.length - 1) !== '*' && !u.endsWith(last)) {
      return false;
    }
    return true;
  }

  private wordpressStableStaticKey(url: string): string {
    const q: number = url.indexOf('?');
    if (q < 0) {
      return '';
    }
    const path: string = url.substring(0, q);
    const query: string = url.substring(q + 1);
    if (query.indexOf('&') >= 0 || query.indexOf('=') < 0) {
      return '';
    }
    const eq: number = query.indexOf('=');
    const key: string = query.substring(0, eq).toLowerCase();
    const value: string = query.substring(eq + 1);
    if (key !== 'ver' || value.length === 0 || !/^[0-9.]+$/.test(value)) {
      return '';
    }
    const lower: string = path.toLowerCase();
    const isWpStatic: boolean =
      lower.indexOf('/wp-content/') >= 0 || lower.indexOf('/wp-includes/') >= 0;
    if (!isWpStatic) {
      return '';
    }
    if (!(lower.endsWith('.js') || lower.endsWith('.css') ||
      lower.endsWith('.woff') || lower.endsWith('.woff2') ||
      lower.endsWith('.ttf') || lower.endsWith('.otf'))) {
      return '';
    }
    return path;
  }

  private matchingWordpressStaticKey(url: string): string {
    const stableKey: string = this.wordpressStableStaticKey(url);
    if (stableKey.length === 0) {
      return '';
    }
    let found: string = '';
    this.diskIndex.forEach((_entry: DiskEntry, key: string) => {
      if (found.length === 0 && this.wordpressStableStaticKey(key) === stableKey) {
        found = key;
      }
    });
    if (found.length > 0) {
      return found;
    }
    this.rawIndex.forEach((_entry: RawEntry, key: string) => {
      if (found.length === 0 && this.wordpressStableStaticKey(key) === stableKey) {
        found = key;
      }
    });
    return found;
  }

  /**
   * 运行时静态资源是否值得写入沙箱。默认无阈值=沿用旧逻辑全部缓存;
   * 配了阈值后,只保留"大资源"或"慢资源",避免 200MB 沙箱被低价值小资源吃掉。
   */
  private shouldStoreRuntimeStatic(url: string, sizeBytes: number, costMs: number): boolean {
    const p: StaticCachePolicy = this.staticPolicyFor(url);
    if (p.enabled === false) {
      return false;
    }
    if (this.matchesAnyPattern(url, p.exclude)) {
      return false;
    }
    if (this.matchesAnyPattern(url, p.include)) {
      return true;
    }
    const maxKB: number = p.maxSizeKB && p.maxSizeKB > 0 ? p.maxSizeKB : 0;
    if (maxKB > 0 && sizeBytes > maxKB * 1024) {
      return false;
    }
    const minKB: number = p.minSizeKB && p.minSizeKB > 0 ? p.minSizeKB : 0;
    const minMs: number = p.minDurationMs && p.minDurationMs > 0 ? p.minDurationMs : 0;
    if (minKB <= 0 && minMs <= 0) {
      return true;
    }
    return (minKB > 0 && sizeBytes >= minKB * 1024) || (minMs > 0 && costMs >= minMs);
  }

  /** 远程下发全局设置(缓存上限 / 文档校验节流)。bytecodeCache 在元服务不支持,已忽略 */
  applySettings(s: RemoteSettings): void {
    if (!s) {
      return;
    }
    if (typeof s.diskCapMB === 'number' && s.diskCapMB > 0) {
      this.diskCapBytes = s.diskCapMB * 1024 * 1024;
    }
    if (typeof s.docCheckSec === 'number' && s.docCheckSec >= 0) {
      this.docCheckMs = s.docCheckSec * 1000;
    }
    if (typeof s.bundleConcurrency === 'number' && s.bundleConcurrency > 0) {
      this.bundleConcurrency = Math.max(1, Math.min(8, Math.floor(s.bundleConcurrency)));
    }
    if (typeof s.prefetchChunks === 'boolean') {
      this.prefetchEnabled = s.prefetchChunks;
    }
    this.staticCachePolicy = { enabled: false };
    hilog.info(DOMAIN, TAG, 'settings applied cap=%{public}dB docCheck=%{public}dms bundleConcurrency=%{public}d prefetch=%{public}s staticMin=%{public}dKB/%{public}dms',
      this.diskCapBytes, this.docCheckMs, this.bundleConcurrency, this.prefetchEnabled ? 'on' : 'off',
      this.staticCachePolicy.minSizeKB ? this.staticCachePolicy.minSizeKB : 0,
      this.staticCachePolicy.minDurationMs ? this.staticCachePolicy.minDurationMs : 0);
  }

  /** 查询某站离线包下载进度(无则返回 null) */
  getBundleProgress(origin: string): BundleProgress | null {
    const p: BundleProgressEntry | undefined = this.bundleProgress.get(origin);
    if (p) {
      return { total: p.total, done: p.done };
    }
    const state: BundleState | undefined = this.bundleState.get(origin);
    if (state && state.urls && state.urls.length > 0) {
      let done: number = 0;
      for (let i = 0; i < state.urls.length; i++) {
        const u: string = state.urls[i];
        if (this.diskIndex.has(u) || this.rawIndex.has(u)) {
          done++;
        }
      }
      return { total: state.urls.length, done: done };
    }
    return null;
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
   * 二级页面加速:解析 webpack 运行时,把站点**全部按需 chunk** 后台预缓存。
   * 点进任何子路由时其 JS 都已在本地。每个站点只跑一次。
   * 框架级能力(Next.js 系有效),由后台 settings.prefetchChunks 控制;非 Next 站本就自动无操作。
   * @param originUrl 该站任意同源 URL(用于取 origin)
   */
  prefetchSiteChunks(originUrl: string): void {
    const om = originUrl.match(/^https?:\/\/[^\/]+/);
    const origin: string = om ? om[0] : '';
    if (origin.length === 0) {
      return;
    }
    if (!this.runtimePrefetchAllowed) {
      return;
    }
    // 每应用 prefetchChunks 覆盖优先;未下发则用全局 prefetchEnabled
    const appOverride: boolean | undefined = origin.length > 0 ? this.prefetchByOrigin.get(origin) : undefined;
    const enabled: boolean = typeof appOverride === 'boolean' ? appOverride : this.prefetchEnabled;
    if (!enabled) {
      return; // 该应用/全局关闭了 chunk 预取
    }
    if (origin.length === 0 || this.prefetchedOrigins.has(origin)) {
      return;
    }
    this.prefetchedOrigins.add(origin);
    const wp: string = this.readWebpackRuntime(origin);
    if (wp.length === 0) {
      hilog.info(DOMAIN, TAG, 'prefetchSiteChunks: no webpack runtime found');
      return;
    }
    // ① webpack 里显式列出的 chunk(static/chunks/xxx.js)
    this.prefetchChunksFromText(origin, wp);
    // ② 计算式 chunk 映射 {id:"hash"} → static/chunks/id.hash.js
    const pairs = wp.match(/(\d+):"([a-f0-9]{6,})"/g);
    if (pairs) {
      for (let i = 0; i < pairs.length; i++) {
        const mm = pairs[i].match(/(\d+):"([a-f0-9]{6,})"/);
        if (mm) {
          this.download(origin + '/_next/static/chunks/' + mm[1] + '.' + mm[2] + '.js');
        }
      }
    }
    hilog.info(DOMAIN, TAG, 'prefetchSiteChunks done');
  }

  /** 从一段文本(webpack 运行时 / RSC)里抽出 static/chunks/*.js 并预取 */
  private prefetchChunksFromText(origin: string, text: string): void {
    const matches = text.match(/static\/chunks\/[A-Za-z0-9\/._-]+\.js/g);
    if (!matches) {
      return;
    }
    const seen: Set<string> = new Set();
    for (let i = 0; i < matches.length; i++) {
      const full: string = origin + '/_next/' + matches[i];
      if (!seen.has(full)) {
        seen.add(full);
        this.download(full); // download 内部会跳过已在沙箱/内置包里的
      }
    }
  }

  /**
   * 通用可缓存判断:只收"内容 hash 命名的不可变静态资源"(任何打包器都适用),
   * 以及 Next.js 图片优化端点。hash 一变 URL 就变 → 永不发旧,无视 No-Store 也安全。
   */
  private shouldTraceStaticMiss(url: string): boolean {
    const q: number = url.indexOf('?');
    const path: string = (q >= 0 ? url.substring(0, q) : url).toLowerCase();
    return path.endsWith('.js') || path.endsWith('.mjs') || path.endsWith('.css') ||
      path.endsWith('.woff') || path.endsWith('.woff2') || path.endsWith('.ttf') ||
      path.endsWith('.otf') || path.endsWith('.eot');
  }

  shouldCache(url: string): boolean {
    if (url.indexOf('/_next/image?') >= 0) {
      return true; // 参数固定→输出确定,已验证可缓存
    }
    const ok: boolean = this.isHashedAsset(url);
    if (ok && this.shouldTraceStaticMiss(url)) {
      hilog.info(DOMAIN, TAG, 'static REQ %{public}s', url);
    }
    return ok;
  }

  /**
   * 文件名是否带"内容 hash"(webpack / vite / CRA / Next 等都这样命名)。
   * 规则:静态扩展名,且文件名里含 ≥8 位的 hash 样 token(全 hex,或字母+数字混合)。
   * 例:webpack-628c76ac231d2361.js ✓ / index.4f3a9b2c.css ✓ / jquery-3.6.0.min.js ✗
   */
  // 版本号型 query 识别:query 各参数值全是纯数字(如 ?2025121805、?v=20250117)才算"版本号"。
  // 必须与后端 cache-builder.js 的 isVersionQuery 完全一致,否则端云判断不一致、离线包命不中。
  // ★ 关键修正(2026-06-25):图片处理 CDN(如 Scaleflex cloudimg.io)用 ?w=500&h=500 这类"尺寸/裁剪"参数
  //   指定同一原图的不同输出,值也是纯数字,会被误判成"版本号 query"→ 缓存后 http 裸抓(无Referer)
  //   拿到坏副本/防盗链响应,且打 max-age 永久缓 → 图片裂(米其林详情页实测)。
  //   所以:query 里出现尺寸/裁剪/质量类参数键时,一律不当版本号(同URL不同输出,缓了会发错)。
  private isVersionQuery(query: string): boolean {
    if (!query || query.length === 0) {
      return false;
    }
    const q: string = query.charAt(0) === '?' ? query.substring(1) : query;
    if (q.length === 0) {
      return false;
    }
    // 变换型参数键(出现即说明"同一资源不同输出"):宽/高/质量/裁剪/格式/dpr/缩放/"小图返原图"等
    const TRANSFORM_KEYS: string[] = [
      'w', 'h', 'width', 'height', 'q', 'quality', 'dpr', 'fit', 'crop', 'func',
      'format', 'fmt', 'resize', 'scale', 'size', 'org_if_sml', 'blur', 'rotate'
    ];
    const parts: string[] = q.split('&');
    for (let i = 0; i < parts.length; i++) {
      const part: string = parts[i];
      const eq: number = part.indexOf('=');
      const key: string = eq >= 0 ? part.substring(0, eq).toLowerCase() : '';
      if (key.length > 0 && TRANSFORM_KEYS.indexOf(key) >= 0) {
        return false; // 尺寸/裁剪类参数 → 不是版本号,不可当不可变缓存
      }
      const v: string = eq >= 0 ? part.substring(eq + 1) : part; // 无 key= 时(如 ?2025121805)取整段
      if (!/^[0-9]+$/.test(v)) {
        return false; // 必须全数字
      }
    }
    return true;
  }

  private isHashedAsset(url: string): boolean {
    const q: number = url.indexOf('?');
    const path: string = q >= 0 ? url.substring(0, q) : url;
    const query: string = q >= 0 ? url.substring(q) : '';
    const slash: number = path.lastIndexOf('/');
    const seg: string = (slash >= 0 ? path.substring(slash + 1) : path).toLowerCase();
    const dot: number = seg.lastIndexOf('.');
    if (dot <= 0) {
      return false;
    }
    if (!STATIC_EXTS.has(seg.substring(dot + 1))) {
      return false;
    }
    // 带版本号 query(纯数字)→ 可缓存(query 变即新 URL,等效 hash);带随机参数 → 不缓(避免缓存爆炸)
    if (query.length > 0) {
      return this.isVersionQuery(query);
    }
    const tokens: string[] = seg.substring(0, dot).split(/[.\-_]/);
    for (let i = 0; i < tokens.length; i++) {
      const t: string = tokens[i];
      if (/^[0-9]+x[0-9]+$/.test(t)) { continue; } // "2160x1140" 等尺寸串不是内容 hash,别误当不可变缓存(否则坏副本永不回源)
      if (t.length >= 8) {
        const isHex: boolean = /^[a-f0-9]+$/.test(t);
        const hasDigit: boolean = /[0-9]/.test(t);
        const hasAlpha: boolean = /[a-z]/.test(t);
        if (isHex || (hasDigit && hasAlpha)) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * onInterceptRequest 的同步入口。
   * @returns 命中返回本地 WebResourceResponse;否则 null(走网络)
   */
  intercept(url: string, method: string, headers: Array<Header>): WebResourceResponse | null {
    if (!this.ready) {
      return null;
    }

    // ⓪ 黑名单:国内不可达、会挂死的外部请求(Google 翻译)→ 立刻空响应,避免卡住 load
    if (this.isBlocked(url)) {
      this.blocked++;
      return this.emptyResponse(url);
    }

    const m: string = method && method.length > 0 ? method.toUpperCase() : 'GET';
    if (m !== 'GET') {
      return null;
    }

    // ★ 主文档 SWR:命中缓存即刻出首屏,后台再拉新版本覆盖(下次启动用新的)
    if (this.docUrls.has(url)) {
      const doc: DiskEntry | undefined = this.diskIndex.get(url);
      if (doc) {
        const buf: ArrayBuffer | null = this.readFile(this.cacheDir + '/' + doc.file);
        if (buf) {
          doc.atime = Date.now();
          this.hitDisk++;
          // 后台做版本校验(节流 60s):重拉 HTML 算指纹,变了=站点更新 → 覆盖缓存并通知页面刷新
          const age: number = Date.now() - (doc.storedAt > 0 ? doc.storedAt : 0);
          if (age > this.docCheckMs) {
            hilog.info(DOMAIN, TAG, 'doc HIT + version check %{public}d B', doc.size);
            this.fetchAndStore(url, '', 'text/html', true);
          } else {
            hilog.info(DOMAIN, TAG, 'doc HIT (checked recently) %{public}d B', doc.size);
          }
          return this.buildResponse(buf, 'text/html', false); // no-cache,保证每次都经过拦截器
        }
        this.totalBytes -= doc.size;
        this.diskIndex.delete(url);
      }
      // 沙箱没有 → 内置包兜底(首启即秒开,无需预热);同时后台拉最新写入沙箱供版本校验
      const rawDoc: RawEntry | undefined = this.rawIndex.get(url);
      if (rawDoc && this.resMgr) {
        try {
          const u8: Uint8Array = this.resMgr.getRawFileContentSync(RAW_DIR + '/' + rawDoc.file);
          const dbuf: ArrayBuffer = u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength);
          this.hitRaw++;
          hilog.info(DOMAIN, TAG, 'doc HIT (bundle) %{public}d B', dbuf.byteLength);
          this.fetchAndStore(url, '', 'text/html', false);
          return this.buildResponse(dbuf, 'text/html', false);
        } catch (e) {
          // 落到网络
        }
      }
      // 都没有:本次透传走网络,同时后台抓存,供下次秒出首屏
      this.miss++;
      hilog.info(DOMAIN, TAG, 'doc MISS -> network + background store');
      this.fetchAndStore(url, '', 'text/html', false);
      return null;
    }

    // ★ RSC(Next.js 客户端路由数据):一律透传走网络。
    //   缓存 RSC 太脆(预取/导航变体、路由状态树差异 → 会服务到错的变体,导致二层卡死/内容错),
    //   且所有路由 chunk 已打进内置包、无需靠 RSC 发现 chunk。所以这里不缓存、不后台抓,保证正确。
    //   RSC 跨境那一下的慢,交给后端镜像解决。
    if (url.indexOf('_rsc=') >= 0) {
      return null;
    }

    let cacheKey: string = url;
    let disk: DiskEntry | undefined = this.diskIndex.get(cacheKey);
    let raw: RawEntry | undefined = this.rawIndex.get(cacheKey);
    if (disk === undefined && raw === undefined) {
      const matchingKey: string = this.matchingWordpressStaticKey(url);
      if (matchingKey.length > 0) {
        cacheKey = matchingKey;
        disk = this.diskIndex.get(cacheKey);
        raw = this.rawIndex.get(cacheKey);
      }
    }
    const explicitBundle: boolean = (disk !== undefined && disk.source === 'bundle') || raw !== undefined;
    if (!explicitBundle && !this.shouldCache(url)) {
      return null;
    }

    // ① 沙箱运行时缓存(最新)
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
          return this.buildResponse(decoded, disk.mime, true);
        }
        const packedPath: string = this.cacheDir + '/' + disk.file;
        let packedExists: boolean = false;
        try {
          packedExists = fs.accessSync(packedPath);
        } catch (e) {
          packedExists = false;
        }
        if (packedExists) {
          disk.atime = Date.now();
          this.warmDecodedEntry(cacheKey, disk);
          this.miss++;
          return null;
        }
        this.totalBytes -= disk.size;
        this.diskIndex.delete(cacheKey);
        this.decodedMemory.delete(cacheKey);
        this.decoding.delete(cacheKey);
        this.reportBundleCorruptIfNeeded(cacheKey);
      }
      const buf: ArrayBuffer | null = this.readFile(this.cacheDir + '/' + disk.file);
      if (buf) {
        disk.atime = Date.now();
        this.hitDisk++;
        return this.buildResponse(buf, disk.mime, true);
      }
      this.totalBytes -= disk.size; // 文件丢了,清脏索引
      this.diskIndex.delete(cacheKey);
      // 自愈:若这个读不出的文件属于某站离线包(不是普通运行时缓存被LRU清掉),上报后台重建该站离线包。
      // 端侧本身已"清脏索引→放行走网络"不会白屏;上报只为让服务端离线包恢复,下个用户首屏即快。
      this.reportBundleCorruptIfNeeded(cacheKey);
    }

    // ② rawfile 内置包
    if (raw) {
      const resp: WebResourceResponse | null = this.serveRaw(raw);
      if (resp) {
        this.hitRaw++;
        return resp;
      }
    }

    // ③ 未命中:直接放行网络。运行时自动回填缓存已禁用。
    this.miss++;
    return null;
  }

  /** 页面加载完成后调用:把本次未命中的静态资源后台抓回,供下次秒开 */
  flushPending(): void {
    this.pending.clear();
  }

  /** 可选:用已知清单主动预热 */
  seed(urls: string[]): void {
    if (!urls || urls.length === 0) {
      return;
    }
    // 端侧不再主动抓取资源写入沙箱。请在后台离线包中配置需要缓存的 URL。
  }

  /** 调试统计快照 */
  stats(): CacheStats {
    return {
      raw: this.rawIndex.size,
      disk: this.diskIndex.size,
      hitRaw: this.hitRaw,
      hitDisk: this.hitDisk,
      miss: this.miss,
      blocked: this.blocked,
      bytes: this.totalBytes,
      inflight: this.inflight.size,
      pending: this.pending.size,
      bundleActive: this.activeBundleDownloads,
      bundleQueued: this.bundleQueue.length,
      lastUrl: this.lastCachedUrl,
      recent: this.recentCached.slice(0),
      caching: this.lastCacheAt > 0 && (Date.now() - this.lastCacheAt) < 3000
    };
  }

  /** 某站(按 origin)已在沙箱缓存的资源条数(给无离线包的应用看"已缓存多少") */
  cachedCountForOrigin(origin: string): number {
    if (origin.length === 0) {
      return 0;
    }
    let n: number = 0;
    this.diskIndex.forEach((e: DiskEntry) => {
      if (e.url.indexOf(origin) === 0) {
        n++;
      }
    });
    return n;
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
    resp.setResponseHeader([{ headerKey: 'Access-Control-Allow-Origin', headerValue: '*' }]);
    resp.setResponseIsReady(true);
    return resp;
  }

  // ——————————————————— 内部实现 ———————————————————

  private buildResponse(buf: ArrayBuffer, mime: string, immutable: boolean): WebResourceResponse {
    const resp: WebResourceResponse = new WebResourceResponse();
    resp.setResponseData(buf);
    resp.setResponseMimeType(mime);
    resp.setResponseEncoding('utf-8');
    resp.setResponseCode(200);
    resp.setReasonMessage('OK');
    // 不可变静态资源:允许内核长缓存;主文档:no-cache,确保每次走拦截器以便 SWR
    const cc: string = immutable ? 'max-age=31536000' : 'no-cache';
    const headers: Array<Header> = [
      { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
      { headerKey: 'Cache-Control', headerValue: cc },
      { headerKey: 'X-Offline-Cache', headerValue: 'HIT' }
    ];
    resp.setResponseHeader(headers);
    resp.setResponseIsReady(true);
    return resp;
  }

  private serveRaw(raw: RawEntry): WebResourceResponse | null {
    if (!this.resMgr) {
      return null;
    }
    try {
      const u8: Uint8Array = this.resMgr.getRawFileContentSync(RAW_DIR + '/' + raw.file);
      const buf: ArrayBuffer = u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength);
      if (raw.encoding && raw.encoding.length > 0) {
        return null;
      }
      return this.buildResponse(buf, raw.mime, true);
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'serveRaw failed: %{public}s', er.message);
      return null;
    }
  }

  private download(url: string): void {
    if (!url || url.length === 0) {
      return;
    }
    // 运行时缓存、路由预取、chunk 预取统一禁用；离线包下载走 enqueueBundleDownload。
  }

  /**
   * 抓取并写入沙箱缓存。来源与缓存 key 分离,使"从后台服务器下载、按原站 URL 缓存"成为可能。
   * @param cacheKey  缓存键(= 原站 URL;拦截器按它命中)
   * @param sourceUrl 实际下载地址(空则 = cacheKey;远程离线包时 = 后台 /bundles/<id>/<file>)
   * @param forceMime 非空则强制用该 mime(主文档用 text/html;离线包用 manifest 里的 mime)
   * @param overwrite 为 true 时即使已缓存也重新抓(SWR revalidate);否则已缓存则跳过
   */
  private fetchAndStore(cacheKey: string, sourceUrl: string, forceMime: string, overwrite: boolean,
    onDone?: (ok: boolean) => void, sourceKind: string = 'runtime',
    contentEncoding: string = '', rawSize: number = 0): void {
    if (sourceKind !== 'bundle') {
      if (onDone) {
        onDone(false);
      }
      return;
    }
    const src: string = sourceUrl && sourceUrl.length > 0 ? sourceUrl : cacheKey;
    if (this.inflight.has(cacheKey)) {
      if (onDone) {
        onDone(false);
      }
      return;
    }
    if (!overwrite && (this.diskIndex.has(cacheKey) || this.rawIndex.has(cacheKey))) {
      if (onDone) {
        onDone(true);
      }
      return; // 已在沙箱或内置包里,不重复下(预取全量 chunk 时靠这个跳过已有的)
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
    const startedAt: number = Date.now();
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
    client.request(src, options, (err: BusinessError, data: http.HttpResponse) => {
      this.inflight.delete(cacheKey);
      let ok: boolean = false;
      try {
        if (!err && data && data.responseCode === 200 && data.result instanceof ArrayBuffer) {
          const body: ArrayBuffer = data.result as ArrayBuffer;
          const costMs: number = Date.now() - startedAt;
          const mime: string = forceMime && forceMime.length > 0 ? forceMime : this.pickMime(cacheKey, data.header);
          const newVersion: string = this.fingerprint(body);
          const old: DiskEntry | undefined = this.diskIndex.get(cacheKey);
          const isDoc: boolean = this.docUrls.has(cacheKey);
          const isBundle: boolean = sourceKind === 'bundle';
          const changed: boolean = old !== undefined && old.version.length > 0 && old.version !== newVersion;

          if (!isDoc && !isBundle && !this.shouldStoreRuntimeStatic(cacheKey, body.byteLength, costMs)) {
            ok = true; // 请求成功,只是按策略不落盘
            hilog.info(DOMAIN, TAG, 'cache SKIP %{public}d B %{public}d ms %{public}s', body.byteLength, costMs, cacheKey);
          } else {
            const file: string = this.fileNameFor(cacheKey);
            this.writeBinary(this.cacheDir + '/' + file, body);
            if (old) {
              this.totalBytes -= old.size; // 覆盖:先扣旧体积
              this.decodedMemory.delete(cacheKey);
              this.decoding.delete(cacheKey);
            }
            const now: number = Date.now();
            const entry: DiskEntry = {
              url: cacheKey, file: file, mime: mime, size: body.byteLength, atime: now, storedAt: now,
              version: newVersion, costMs: costMs, source: sourceKind,
              encoding: contentEncoding && contentEncoding.length > 0 ? contentEncoding : undefined,
              rawSize: rawSize > 0 ? rawSize : undefined
            };
            this.diskIndex.set(cacheKey, entry);
            this.totalBytes += body.byteLength;
            this.evictIfNeeded();
            this.saveDiskIndex();
            if (entry.encoding && entry.encoding.length > 0) {
              this.warmDecodedEntry(cacheKey, entry);
            }
            this.markBundleResource(cacheKey); // 若属于某站离线包,推进其下载进度
            ok = true;
            this.lastCacheAt = Date.now();     // 记"真的缓存成功"的时刻
            hilog.info(DOMAIN, TAG, 'cache STORE %{public}s %{public}d B %{public}d ms %{public}s %{public}s %{public}s',
              mime, body.byteLength, costMs, sourceKind,
              contentEncoding && contentEncoding.length > 0 ? contentEncoding : '-', cacheKey);

            // 主文档版本变了 = 站点更新 → 通知(池)刷新对应节点,立即用上新版
            if (isDoc && changed) {
              hilog.info(DOMAIN, TAG, 'doc VERSION CHANGED %{public}s', cacheKey);
              if (this.docUpdateHandler) {
                this.docUpdateHandler(cacheKey);
              }
            }
          }
        }
      } catch (e) {
        const er = e as BusinessError;
        hilog.error(DOMAIN, TAG, 'store failed: %{public}s', er.message);
      }
      client.destroy();
      if (onDone) {
        onDone(ok);
      }
    });
  }

  /** 远程离线包下载任务入队,用有限并发避免抢占首屏主链路 */
  private enqueueBundleDownload(entry: RawEntry, sourceUrl: string): void {
    if (this.diskIndex.has(entry.url) || this.rawIndex.has(entry.url) || this.inflight.has(entry.url) ||
      this.bundleQueueSources.has(entry.url)) {
      return;
    }
    this.bundleQueue.push(entry);
    this.bundleQueueSources.set(entry.url, sourceUrl);
    this.pumpBundleQueue();
  }

  private pumpBundleQueue(): void {
    while (this.activeBundleDownloads < this.bundleConcurrency && this.bundleQueue.length > 0) {
      const entry: RawEntry | undefined = this.bundleQueue.shift();
      if (!entry) {
        return;
      }
      const src: string | undefined = this.bundleQueueSources.get(entry.url);
      this.bundleQueueSources.delete(entry.url);
      if (!src || src.length === 0) {
        continue;
      }
      if (this.diskIndex.has(entry.url) || this.rawIndex.has(entry.url)) {
        this.markBundleResource(entry.url);
        continue;
      }
      this.activeBundleDownloads++;
      const rawSize: number = entry.rawSize && entry.rawSize > 0 ? entry.rawSize : 0;
      this.fetchAndStore(entry.url, src, entry.mime, false, (_ok: boolean) => {
        this.activeBundleDownloads--;
        this.pumpBundleQueue();
      }, 'bundle', entry.encoding ? entry.encoding : '', rawSize);
    }
  }

  /**
   * 远程离线包:从后台 manifest 把该站资源下载进沙箱(缓存 key = 原站 URL)。
   * 这是"App 缓存去服务器下载"的核心入口,替代打进 HAP 的内置包。
   * @param siteUrl     站点任意 URL(取 origin,完成后通知补注入字节码)
   * @param manifestUrl 后台 manifest 全地址(如 http://server:8787/bundles/<id>/manifest.json)
   */
  async loadRemoteBundle(siteUrl: string, manifestUrl: string, bundleVersion: string = ''): Promise<void> {
    const om = siteUrl.match(/^https?:\/\/[^\/]+/);
    const origin: string = om ? om[0] : '';
    if (origin.length === 0 || manifestUrl.length === 0) {
      return;
    }
    // 版本门:已应用版本 == 当前下发版本 → 离线包无变化,直接用本地(连清单都不拉)
    const applied: BundleState | undefined = this.bundleState.get(origin);
    if (bundleVersion.length > 0 && applied !== undefined && applied.version === bundleVersion) {
      this.warmCompressedDiskEntriesForUrls(applied.urls);
      return;
    }
    if (this.loadedBundles.has(origin)) {
      if (applied !== undefined) {
        this.warmCompressedDiskEntriesForUrls(applied.urls);
      }
      if (bundleVersion.length > 0) {
        const current: BundleState | undefined = this.bundleState.get(origin);
        if (current !== undefined && current.version !== bundleVersion) {
          this.bundleState.set(origin, { origin: origin, version: bundleVersion, urls: current.urls });
          this.saveBundleState();
          hilog.info(DOMAIN, TAG, 'bundle version recorded after refresh: %{public}s', bundleVersion);
        } else if (current === undefined) {
          this.pendingBundleVersionByOrigin.set(origin, bundleVersion);
          hilog.info(DOMAIN, TAG, 'bundle version pending until current download completes: %{public}s', bundleVersion);
        }
      }
      return; // 本次会话已处理过该站
    }
    this.loadedBundles.add(origin);
    const base: string = manifestUrl.replace(/\/manifest(?:\.[A-Za-z0-9_-]+)?\.json.*$/, ''); // 后台资源目录
    const txt: string = await this.httpGetText(manifestUrl);
    if (txt.length === 0) {
      hilog.warn(DOMAIN, TAG, 'remote bundle manifest unreachable: %{public}s', manifestUrl);
      this.loadedBundles.delete(origin);
      return;
    }
    let arr: RawEntry[] = [];
    try {
      arr = JSON.parse(txt) as RawEntry[];
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'remote manifest parse failed: %{public}s', er.message);
      this.loadedBundles.delete(origin);
      return;
    }
    let total: number = 0;
    let done: number = 0;
    const expected: Set<string> = new Set();
    const newUrls: string[] = [];
    const appPolicy: StaticCachePolicy | undefined = this.staticPolicyByOrigin.get(origin);
    for (let i = 0; i < arr.length; i++) {
      const e: RawEntry = arr[i];
      if (!e || !e.url || !e.file) {
        continue;
      }
      if (appPolicy !== undefined) {
        const rm: RegExpMatchArray | null = e.url.match(/^https?:\/\/[^\/]+/);
        const resourceOrigin: string = rm ? rm[0] : '';
        if (resourceOrigin.length > 0 && !this.staticPolicyByOrigin.has(resourceOrigin)) {
          this.staticPolicyByOrigin.set(resourceOrigin, appPolicy);
        }
      }
      // 主文档只有启用 SWR 时才会被 intercept 使用。未启用时跳过 HTML,避免无效占用沙箱。
      if (e.mime === 'text/html' && !this.docUrls.has(e.url)) {
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
      if (this.rawIndex.has(e.url)) {
        done++;
      } else {
        expected.add(e.url);
        this.enqueueBundleDownload(e, base + '/' + e.file); // 来源=后台文件,缓存 key=原站 URL
      }
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
    const pendingVersion: string | undefined = this.pendingBundleVersionByOrigin.get(origin);
    const effectiveVersion: string = bundleVersion.length > 0 ? bundleVersion : (pendingVersion !== undefined ? pendingVersion : '');
    this.pendingBundleVersionByOrigin.delete(origin);
    this.bundleState.set(origin, { origin: origin, version: effectiveVersion, urls: newUrls });
    this.saveBundleState();
    const prog: BundleProgressEntry = { total: total, done: done, expected: expected };
    this.bundleProgress.set(origin, prog);
    hilog.info(DOMAIN, TAG, 'remote bundle: total %{public}d, to download %{public}d, ver %{public}s',
      total, total - done, effectiveVersion.length > 0 ? effectiveVersion : '(none)');
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

  /** 内容指纹(DJB2 over bytes),用于判断主文档是否变了 */
  private fingerprint(buf: ArrayBuffer): string {
    const u8 = new Uint8Array(buf);
    let h1: number = 5381;
    let h2: number = 52711;
    const step: number = u8.length > 65536 ? 7 : 1; // 大文件抽样,够区分版本即可
    for (let i = 0; i < u8.length; i += step) {
      const c: number = u8[i];
      h1 = ((h1 * 33) ^ c) >>> 0;
      h2 = ((h2 * 33) ^ c) >>> 0;
    }
    return (h1 >>> 0).toString(16) + (h2 >>> 0).toString(16) + '-' + u8.length.toString(16);
  }

  /** 取某站 webpack 运行时 chunk 的文本(从内置包或沙箱缓存里找) */
  private readWebpackRuntime(origin: string): string {
    // 先内置包
    let found: RawEntry | null = null;
    this.rawIndex.forEach((v: RawEntry) => {
      if (found === null && v.url.indexOf(origin) === 0 && v.url.indexOf('/chunks/webpack-') >= 0) {
        found = v;
      }
    });
    if (found !== null && this.resMgr) {
      try {
        const u8: Uint8Array = this.resMgr.getRawFileContentSync(RAW_DIR + '/' + (found as RawEntry).file);
        return util.TextDecoder.create('utf-8').decodeToString(u8);
      } catch (e) {
        // 落到沙箱再找
      }
    }
    // 再沙箱
    let dpath: string = '';
    this.diskIndex.forEach((v: DiskEntry) => {
      if (dpath.length === 0 && v.url.indexOf(origin) === 0 && v.url.indexOf('/chunks/webpack-') >= 0) {
        dpath = this.cacheDir + '/' + v.file;
      }
    });
    if (dpath.length > 0) {
      const b: ArrayBuffer | null = this.readFile(dpath);
      if (b) {
        return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(b));
      }
    }
    return '';
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

  private warmCompressedDiskEntries(): void {
    this.diskIndex.forEach((entry: DiskEntry, url: string) => {
      if (entry.encoding && entry.encoding.length > 0) {
        this.warmDecodedEntry(url, entry);
      }
    });
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

  private loadRawManifest(): void {
    if (!this.resMgr) {
      return;
    }
    try {
      const u8: Uint8Array = this.resMgr.getRawFileContentSync(RAW_DIR + '/manifest.json');
      const txt: string = util.TextDecoder.create('utf-8').decodeToString(u8);
      if (txt && txt.length > 0) {
        const arr = JSON.parse(txt) as RawEntry[];
        for (let i = 0; i < arr.length; i++) {
          const e: RawEntry = arr[i];
          this.rawIndex.set(e.url, e);
        }
      }
    } catch (e) {
      // 没有内置包也能正常工作(纯运行时缓存)
      hilog.info(DOMAIN, TAG, 'no raw manifest bundled');
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
            this.bundleState.set(s.origin, {
              origin: s.origin, version: s.version ? s.version : '', urls: s.urls ? s.urls : []
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

  /** 取/建匿名上报 id(持久化在沙箱,不含任何个人信息) */
  private ensureAnonId(): string {
    if (this.anonId.length > 0) {
      return this.anonId;
    }
    const p: string = this.cacheDir + '/anon-id.txt';
    try {
      const buf: ArrayBuffer | null = this.readFile(p);
      if (buf) {
        const t: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf)).trim();
        if (t.length > 0) {
          this.anonId = t;
          return t;
        }
      }
    } catch (e) { /* 首次无文件 */ }
    const id: string = Date.now().toString(36) + Math.floor(Math.random() * 1e9).toString(36);
    try {
      const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, id);
      fs.closeSync(f);
    } catch (e) { /* 写失败也不影响本次内存值 */ }
    this.anonId = id;
    return id;
  }

  /** 采集某站本地已缓存的静态资源(url + 指纹 + mime + 体积),供探索上报 */
  private collectForReport(origin: string, max: number): ReportItem[] {
    const out: ReportItem[] = [];
    this.diskIndex.forEach((e: DiskEntry, url: string) => {
      if (out.length < max && url.indexOf(origin) === 0 && e.version.length > 0) {
        out.push({ url: url, hash: e.version, mime: e.mime, size: e.size });
      }
    });
    return out;
  }

  /** 众包探索上报:按采样率把某站本地已缓存的静态资源匿名报给后台,供共识判定可缓存性 */
  reportExploration(appId: string, origin: string, server: string, sample: number): void {
    if (server.length === 0 || sample <= 0) {
      return;
    }
    if (Math.random() > sample) {
      return; // 采样:只一部分用户上报,整体减负
    }
    const resources: ReportItem[] = this.collectForReport(origin, 200);
    if (resources.length === 0) {
      return;
    }
    const body: ReportBody = { appId: appId, anonId: this.ensureAnonId(), resources: resources };
    const client = http.createHttp();
    const header: Record<string, string> = { 'Content-Type': 'application/json' };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: header,
      extraData: JSON.stringify(body),
      connectTimeout: 15000,
      readTimeout: 30000
    };
    client.request(server + '/api/report', options, (err: BusinessError, data: http.HttpResponse) => {
      client.destroy();
      if (!err && data) {
        hilog.info(DOMAIN, TAG, 'explore report %{public}s code=%{public}d n=%{public}d', appId, data.responseCode, resources.length);
      }
    });
  }

  /**
   * 离线包资源实际读不出(文件丢/坏)→ 上报后台自愈重建该站离线包。
   * 仅当该 url 属于某 bundle:true 站时才报(普通运行时缓存被 LRU 清掉不报);本会话每站只报一次,避免刷请求。
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
