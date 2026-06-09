import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RemoteSettings } from './RemoteConfig';

const TAG: string = 'WebCache';
const DOMAIN: number = 0x0001;
const RAW_DIR: string = 'webcache';                 // rawfile 下的目录
const DISK_CAP_BYTES: number = 64 * 1024 * 1024;    // 沙箱运行时缓存总量上限 64MB
const DOC_CHECK_MS: number = 60 * 1000;             // 主文档版本校验节流:60 秒内不重复校验
const BUNDLE_CONCURRENCY: number = 3;               // 远程离线包后台下载并发上限

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
  private bundleProgress: Map<string, BundleProgressEntry> = new Map(); // 各站离线包下载进度(按 origin)

  /** 启动时调用一次(EntryAbility.onCreate) */
  init(context: common.UIAbilityContext): void {
    try {
      this.resMgr = context.resourceManager;
      this.cacheDir = context.filesDir + '/webcache';
      this.indexPath = this.cacheDir + '/index.json';
      if (!fs.accessSync(this.cacheDir)) {
        fs.mkdirSync(this.cacheDir, true);
      }
      this.loadRawManifest();
      this.loadDiskIndex();
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
    for (let i = 0; i < urls.length; i++) {
      this.docUrls.add(urls[i]);
    }
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
    hilog.info(DOMAIN, TAG, 'settings applied cap=%{public}dB docCheck=%{public}dms bundleConcurrency=%{public}d prefetch=%{public}s',
      this.diskCapBytes, this.docCheckMs, this.bundleConcurrency, this.prefetchEnabled ? 'on' : 'off');
  }

  /** 查询某站离线包下载进度(无则返回 null) */
  getBundleProgress(origin: string): BundleProgress | null {
    const p: BundleProgressEntry | undefined = this.bundleProgress.get(origin);
    if (!p) {
      return null;
    }
    return { total: p.total, done: p.done };
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
    if (!this.prefetchEnabled) {
      return; // 后台关闭了全站 chunk 预取
    }
    const om = originUrl.match(/^https?:\/\/[^\/]+/);
    const origin: string = om ? om[0] : '';
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
  shouldCache(url: string): boolean {
    if (url.indexOf('/_next/image?') >= 0) {
      return true; // 参数固定→输出确定,已验证可缓存
    }
    return this.isHashedAsset(url);
  }

  /**
   * 文件名是否带"内容 hash"(webpack / vite / CRA / Next 等都这样命名)。
   * 规则:静态扩展名,且文件名里含 ≥8 位的 hash 样 token(全 hex,或字母+数字混合)。
   * 例:webpack-628c76ac231d2361.js ✓ / index.4f3a9b2c.css ✓ / jquery-3.6.0.min.js ✗
   */
  private isHashedAsset(url: string): boolean {
    const q: number = url.indexOf('?');
    const path: string = q >= 0 ? url.substring(0, q) : url;
    const slash: number = path.lastIndexOf('/');
    const seg: string = (slash >= 0 ? path.substring(slash + 1) : path).toLowerCase();
    const dot: number = seg.lastIndexOf('.');
    if (dot <= 0) {
      return false;
    }
    if (!STATIC_EXTS.has(seg.substring(dot + 1))) {
      return false;
    }
    const tokens: string[] = seg.substring(0, dot).split(/[.\-_]/);
    for (let i = 0; i < tokens.length; i++) {
      const t: string = tokens[i];
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

    if (!this.shouldCache(url)) {
      return null;
    }

    // ① 沙箱运行时缓存(最新)
    const disk: DiskEntry | undefined = this.diskIndex.get(url);
    if (disk) {
      const buf: ArrayBuffer | null = this.readFile(this.cacheDir + '/' + disk.file);
      if (buf) {
        disk.atime = Date.now();
        this.hitDisk++;
        return this.buildResponse(buf, disk.mime, true);
      }
      this.totalBytes -= disk.size; // 文件丢了,清脏索引
      this.diskIndex.delete(url);
    }

    // ② rawfile 内置包
    const raw: RawEntry | undefined = this.rawIndex.get(url);
    if (raw) {
      const resp: WebResourceResponse | null = this.serveRaw(raw);
      if (resp) {
        this.hitRaw++;
        return resp;
      }
    }

    // ③ 未命中:放行,记 pending,等页面加载完再回填(不抢首屏带宽)
    this.miss++;
    if (!this.inflight.has(url) && !this.rawIndex.has(url)) {
      this.pending.add(url);
    }
    return null;
  }

  /** 页面加载完成后调用:把本次未命中的静态资源后台抓回,供下次秒开 */
  flushPending(): void {
    if (this.pending.size === 0) {
      return;
    }
    const urls: string[] = [];
    this.pending.forEach((u: string) => {
      urls.push(u);
    });
    this.pending.clear();
    for (let i = 0; i < urls.length; i++) {
      this.download(urls[i]);
    }
    hilog.info(DOMAIN, TAG, 'flush %{public}d pending', urls.length);
  }

  /** 可选:用已知清单主动预热 */
  seed(urls: string[]): void {
    for (let i = 0; i < urls.length; i++) {
      if (this.shouldCache(urls[i]) && !this.diskIndex.has(urls[i]) && !this.rawIndex.has(urls[i])) {
        this.download(urls[i]);
      }
    }
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
      bundleQueued: this.bundleQueue.length
    };
  }

  /** 是否命中黑名单(会挂死的外部请求) */
  private isBlocked(url: string): boolean {
    for (let i = 0; i < this.blockHosts.length; i++) {
      if (url.indexOf(this.blockHosts[i]) >= 0) {
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
      return this.buildResponse(buf, raw.mime, true);
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'serveRaw failed: %{public}s', er.message);
      return null;
    }
  }

  private download(url: string): void {
    this.fetchAndStore(url, '', '', false);
  }

  /**
   * 抓取并写入沙箱缓存。来源与缓存 key 分离,使"从后台服务器下载、按原站 URL 缓存"成为可能。
   * @param cacheKey  缓存键(= 原站 URL;拦截器按它命中)
   * @param sourceUrl 实际下载地址(空则 = cacheKey;远程离线包时 = 后台 /bundles/<id>/<file>)
   * @param forceMime 非空则强制用该 mime(主文档用 text/html;离线包用 manifest 里的 mime)
   * @param overwrite 为 true 时即使已缓存也重新抓(SWR revalidate);否则已缓存则跳过
   */
  private fetchAndStore(cacheKey: string, sourceUrl: string, forceMime: string, overwrite: boolean,
    onDone?: (ok: boolean) => void): void {
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
    client.request(src, options, (err: BusinessError, data: http.HttpResponse) => {
      this.inflight.delete(cacheKey);
      let ok: boolean = false;
      try {
        if (!err && data && data.responseCode === 200 && data.result instanceof ArrayBuffer) {
          const body: ArrayBuffer = data.result as ArrayBuffer;
          const mime: string = forceMime && forceMime.length > 0 ? forceMime : this.pickMime(cacheKey, data.header);
          const newVersion: string = this.fingerprint(body);
          const old: DiskEntry | undefined = this.diskIndex.get(cacheKey);
          const isDoc: boolean = this.docUrls.has(cacheKey);
          const changed: boolean = old !== undefined && old.version.length > 0 && old.version !== newVersion;

          const file: string = this.fileNameFor(cacheKey);
          this.writeBinary(this.cacheDir + '/' + file, body);
          if (old) {
            this.totalBytes -= old.size; // 覆盖:先扣旧体积
          }
          const now: number = Date.now();
          const entry: DiskEntry = {
            url: cacheKey, file: file, mime: mime, size: body.byteLength, atime: now, storedAt: now, version: newVersion
          };
          this.diskIndex.set(cacheKey, entry);
          this.totalBytes += body.byteLength;
          this.evictIfNeeded();
          this.saveDiskIndex();
          this.markBundleResource(cacheKey); // 若属于某站离线包,推进其下载进度
          ok = true;
          hilog.info(DOMAIN, TAG, 'cached %{public}s %{public}d B', mime, body.byteLength);

          // 主文档版本变了 = 站点更新 → 通知(池)刷新对应节点,立即用上新版
          if (isDoc && changed) {
            hilog.info(DOMAIN, TAG, 'doc VERSION CHANGED %{public}s', cacheKey);
            if (this.docUpdateHandler) {
              this.docUpdateHandler(cacheKey);
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
      this.fetchAndStore(entry.url, src, entry.mime, false, (_ok: boolean) => {
        this.activeBundleDownloads--;
        this.pumpBundleQueue();
      });
    }
  }

  /**
   * 远程离线包:从后台 manifest 把该站资源下载进沙箱(缓存 key = 原站 URL)。
   * 这是"App 缓存去服务器下载"的核心入口,替代打进 HAP 的内置包。
   * @param siteUrl     站点任意 URL(取 origin,完成后通知补注入字节码)
   * @param manifestUrl 后台 manifest 全地址(如 http://server:8787/bundles/<id>/manifest.json)
   */
  async loadRemoteBundle(siteUrl: string, manifestUrl: string): Promise<void> {
    const om = siteUrl.match(/^https?:\/\/[^\/]+/);
    const origin: string = om ? om[0] : '';
    if (origin.length === 0 || manifestUrl.length === 0) {
      return;
    }
    if (this.loadedBundles.has(origin)) {
      return; // 本次会话已拉过该站离线包,不重复拉 manifest
    }
    this.loadedBundles.add(origin);
    const base: string = manifestUrl.replace(/\/manifest\.json.*$/, ''); // 后台资源目录
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
    for (let i = 0; i < arr.length; i++) {
      const e: RawEntry = arr[i];
      if (!e || !e.url || !e.file) {
        continue;
      }
      total++;
      if (this.diskIndex.has(e.url) || this.rawIndex.has(e.url)) {
        done++; // 已在缓存里,算已完成
      } else {
        expected.add(e.url);
        // 来源 = 后台文件,缓存 key = 原站 URL(拦截器按原站 URL 命中)
        this.enqueueBundleDownload(e, base + '/' + e.file);
      }
    }
    const prog: BundleProgressEntry = { total: total, done: done, expected: expected };
    this.bundleProgress.set(origin, prog);
    hilog.info(DOMAIN, TAG, 'remote bundle: total %{public}d, to download %{public}d, from %{public}s',
      total, total - done, manifestUrl);
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
