import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { webCache, CacheStats, BundleProgress } from './core/WebCacheManager';
import { webPool, WebNode } from './core/WebPreRender';
import {
  remoteConfig,
  RemoteApp,
  ConfigureOptions,
  ConfigRefreshOptions,
  ConfigRefreshResult,
  ConfigRefreshState,
  remoteAppMatchesRegion,
  remoteAppRegions
} from './core/RemoteConfig';

export { ConfigRefreshOptions, ConfigRefreshResult, ConfigRefreshState } from './core/RemoteConfig';

const TAG: string = 'WebAccel';
const DOMAIN: number = 0x0001;
const DEFAULT_CONFIG_REFRESH_SEC: number = 300;
const MIN_CONFIG_REFRESH_SEC: number = 30;

/**
 * WebAccel.init 入参(继承 ConfigureOptions 的 configServer/apps/blockHosts/settings)。全部可选:
 *  - 只填 configServer → 开机从 admin 后台拉应用列表/黑名单/设置(标准模式);
 *  - 只填 apps        → 不联网,直接用给定列表(纯本地/直连模式,元服务也可这样用);
 *  - 两者都填         → apps 作默认兜底,后台配置拉到后覆盖。
 */
export interface WebAccelOptions extends ConfigureOptions {
  autoRefresh?: boolean;     // 有 configServer 时是否开机异步拉最新配置(默认 true)
  configRefreshSec?: number; // 后台应用 JSON 轮询间隔;<=0 关闭,默认 300 秒
}

/**
 * 网页加速 SDK 门面(全静态)。负责远程配置、后台离线包和 WebView 本地命中。
 *
 * 典型接入(3 步):
 *   ① UIAbility.onCreate:   WebAccel.init(this.context, { configServer })
 *   ② 首个页面 aboutToAppear: WebAccel.attach(this.getUIContext()); WebAccel.prewarm(url)
 *   ③ 展示页:                WebAccelView({ url })   // 或自行 NodeContainer(WebAccel.obtain(url))
 *
 * 元服务(Atomic Service)注意:不要打 rawfile 离线包，后台资源只落到应用沙箱。
 */
export class WebAccel {
  private static refreshTimerId: number = -1;
  private static refreshSecOverride: number = -1;
  private static refreshRequestSequence: number = 0;
  private static activeRefreshRequestId: number = 0;
  private static refreshTask: Promise<ConfigRefreshResult> | null = null;
  private static refreshState: ConfigRefreshState = {
    requestId: 0,
    status: 'idle',
    running: false,
    reason: '',
    startedAt: 0,
    finishedAt: 0
  };

  /**
   * 开机初始化(在 UIAbility.onCreate 调用一次)。内部:
   *   提前初始化 Web 内核 → 初始化离线缓存 → 注入配置 → 同步读缓存/直供 → (可选)异步拉后台最新配置。
   */
  static init(context: common.UIAbilityContext, options?: WebAccelOptions): void {
    // ① 提前初始化 Web 内核:首屏创建 Web 组件时无需再等内核冷启动
    try {
      webview.WebviewController.initializeWebEngine();
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'initializeWebEngine failed: %{public}d %{public}s', e.code, e.message);
    }

    // ② 初始化离线缓存(同步加载磁盘索引):拦截不可变资源,绕过 No-Store 跨境慢链路
    webCache.init(context);

    // ③ 注入配置(后台地址 / 直供列表 / 黑名单 / 设置),必须在 load 之前
    remoteConfig.configure(options);

    // ④ 同步:先用上次缓存(或直供/兜底),不阻塞首屏
    remoteConfig.load(context);
    webCache.setBlockHosts(remoteConfig.getBlockHosts());
    webCache.applySettings(remoteConfig.getSettings());
    webCache.applyApps(remoteConfig.getApps(), remoteConfig.getServer()); // 每应用黑名单、UA 和离线包归属按 origin 生效
    webPool.bindRemoteConfig();
    webPool.loadTopBundles();

    // ⑤ 异步:有后台且允许时拉服务器最新配置,成功后再注入一次
    const autoRefresh: boolean = !(options && options.autoRefresh === false);
    if (autoRefresh) {
      WebAccel.refreshSecOverride = options && typeof options.configRefreshSec === 'number' ? options.configRefreshSec : -1;
      WebAccel.refreshConfig();
      WebAccel.startConfigAutoRefresh(options);
    }
    hilog.info(DOMAIN, TAG, 'initialized (server=%{public}s)',
      remoteConfig.getServer().length > 0 ? remoteConfig.getServer() : '(none)');
  }

  /** 后台应用 JSON 会变,端侧需要周期性拉取,否则长期前台会一直使用旧配置。 */
  private static startConfigAutoRefresh(options?: WebAccelOptions): void {
    if (WebAccel.refreshTimerId >= 0) {
      clearInterval(WebAccel.refreshTimerId);
      WebAccel.refreshTimerId = -1;
    }
    if (remoteConfig.getServer().length === 0) {
      return;
    }
    let sec: number = DEFAULT_CONFIG_REFRESH_SEC;
    const optionSec: number = options && typeof options.configRefreshSec === 'number'
      ? options.configRefreshSec
      : WebAccel.refreshSecOverride;
    if (optionSec === 0) {
      return;
    }
    if (optionSec > 0) {
      sec = optionSec;
    } else {
      const settingsSec: number = remoteConfig.getSettings() && typeof remoteConfig.getSettings().configRefreshSec === 'number'
        ? remoteConfig.getSettings().configRefreshSec as number
        : -1;
      if (settingsSec === 0) {
        return;
      }
      if (settingsSec > 0) {
        sec = settingsSec;
      }
    }
    sec = Math.max(MIN_CONFIG_REFRESH_SEC, Math.floor(sec));
    WebAccel.refreshTimerId = setInterval(() => {
      WebAccel.refreshConfig();
    }, sec * 1000);
    hilog.info(DOMAIN, TAG, 'config auto refresh every %{public}d sec', sec);
  }

  /** 后台配置刷新后,立即按当前地区重新匹配并拉取新配置的地区离线包。 */
  private static reloadActiveRegionBundles(): void {
    const activeRegion: string = webCache.getActiveRegion();
    if (activeRegion.length === 0) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'reload active region bundles after config refresh region=%{public}s', activeRegion);
    webPool.switchRegion(activeRegion);
  }

  /** 兼容旧接入；Web 节点现在只在 NodeContainer 挂载时创建。 */
  static attach(uiContext: UIContext): void {
    webPool.setUIContext(uiContext);
  }

  /**
   * 兼容旧接入的预热入口。当前只登记 Web 节点，不做 SWR 或离屏预渲染。
   */
  static prewarm(url: string, swrDoc: boolean = true): void {
    webPool.prewarm(url, swrDoc);
  }

  /** 取一个按需创建的网页节点(WebAccelView 内部用;也可自行 NodeContainer 挂载)。 */
  static obtain(url: string): WebNode {
    return webPool.obtain(url);
  }

  /** 按当前远程配置触发指定网页应用的离线包下载,不打开 WebView。 */
  static loadBundle(url: string): void {
    webPool.loadBundle(url);
  }

  /** 按指定 app 的 id/manifestUrl 精确触发离线包下载。适用于同一 URL 同时存在 TOP 和地区配置的场景。 */
  static loadBundleForApp(app: RemoteApp): void {
    webPool.loadBundleForApp(app);
  }

  /** 初始化/配置刷新后主动拉 top 常驻离线包。通常 init 内部已调用,这里给宿主手动重试 */
  static loadTopBundles(): void {
    webPool.loadTopBundles();
  }

  /**
   * 切换应用地区。旧地区下载任务会失效,旧地区沙箱缓存会删除;top 常驻包保留。
   * 后台应把香港/英国等地区资源配置为 scope='region' 且 region=地区 id。
   */
  static switchRegion(region: string): void {
    webPool.switchRegion(region);
  }

  /** 删除某地区离线包缓存,不影响 top */
  static deleteRegion(region: string): void {
    webCache.deleteRegion(region);
  }

  /** 删除某个网址 id 的离线包缓存 */
  static deleteBundle(id: string): void {
    webCache.deleteBundle(id);
  }

  /**
   * 给外部 WebView 容器使用的 SchemeHandler 接口。
   * 命中离线包时返回 true 并写入响应;未命中返回 false,宿主继续放行网络。
   */
  static handleSchemeRequest(request: webview.WebSchemeHandlerRequest,
    handler: webview.WebResourceHandler): boolean {
    return webCache.handleSchemeRequest(request, handler);
  }

  /** 获取随离线包保存的 H5 配置 JSON,用于宿主 getAppInfo 接口失败时兜底注入 */
  static interceptRequest(url: string, method: string, headers: Array<Header>): WebResourceResponse | null {
    return webCache.intercept(url, method, headers);
  }

  static shouldDropUnbundledRequest(url: string, method: string): boolean {
    return webCache.shouldDropUnbundledRequest(url, method);
  }

  static dropResponse(url: string): WebResourceResponse {
    return webCache.dropResponse(url);
  }

  static getConfigJson(idOrUrl: string): string {
    return webCache.getConfigJson(idOrUrl);
  }

  /** 宿主从业务接口拿到最新 configJson 后,可同步给 SDK 做离线兜底 */
  static updateConfigJson(idOrUrl: string, configJson: string): void {
    webCache.updateConfigJson(idOrUrl, configJson);
  }

  /** 该网页能后退则后退,返回是否消费了返回事件。宿主页 onBackPress 里转调即可 */
  static goBack(url: string): boolean {
    return webPool.goBack(url);
  }

  /** 当前应用列表(来自后台 / 缓存 / 直供) */
  static getApps(): RemoteApp[] {
    return remoteConfig.getApps();
  }

  /** 当前实际使用的配置服务器；宿主解析相对 manifest 地址时必须使用该值。 */
  static getConfigServer(): string {
    return remoteConfig.getServer();
  }

  /** 返回应用配置的全部地区 ID。兼容旧配置中的单值 region。 */
  static getAppRegions(app: RemoteApp): string[] {
    return remoteAppRegions(app);
  }

  /** 判断应用是否可用于当前地区。TOP 应用始终返回 true。 */
  static matchesRegion(app: RemoteApp, region: string): boolean {
    return remoteAppMatchesRegion(app, region);
  }

  /** 运行时直接喂应用列表(不依赖后台;会写入 AppStorage('apps') 并触发 @StorageLink 刷新) */
  static setApps(apps: RemoteApp[]): void {
    remoteConfig.setApps(apps);
  }

  /**
   * 手动拉一次后台最新配置。并发调用会复用同一任务；结果明确区分成功、失败、取消和被替代。
   */
  static refreshConfig(options?: ConfigRefreshOptions): Promise<ConfigRefreshResult> {
    if (WebAccel.refreshTask !== null && WebAccel.refreshState.running) {
      hilog.info(DOMAIN, TAG, 'refreshConfig deduped: reuse request=%{public}d',
        WebAccel.refreshState.requestId);
      return WebAccel.refreshTask;
    }
    const requestId: number = ++WebAccel.refreshRequestSequence;
    const startedAt: number = Date.now();
    WebAccel.activeRefreshRequestId = requestId;
    WebAccel.refreshState = {
      requestId,
      status: 'running',
      running: true,
      reason: options && options.reason ? options.reason : '',
      startedAt,
      finishedAt: 0
    };
    const task: Promise<ConfigRefreshResult> = WebAccel.executeConfigRefresh(requestId, startedAt);
    WebAccel.refreshTask = task;
    return task;
  }

  private static async executeConfigRefresh(requestId: number, startedAt: number): Promise<ConfigRefreshResult> {
    let result: ConfigRefreshResult;
    try {
      result = await remoteConfig.refresh(requestId, startedAt);
      if (result.success && requestId === WebAccel.activeRefreshRequestId) {
        webCache.setBlockHosts(remoteConfig.getBlockHosts());
        webCache.applySettings(remoteConfig.getSettings());
        webCache.applyApps(remoteConfig.getApps(), remoteConfig.getServer()); // 每应用精细配置按 origin 生效
        webPool.loadTopBundles();
        WebAccel.reloadActiveRegionBundles();
        webPool.reloadOpenedBundles();
        WebAccel.startConfigAutoRefresh();
      }
    } catch (e) {
      const error = e as BusinessError;
      result = {
        requestId,
        status: requestId === WebAccel.activeRefreshRequestId ? 'failed' : 'superseded',
        success: false,
        message: error.message,
        startedAt,
        finishedAt: Date.now()
      };
    }
    if (requestId === WebAccel.activeRefreshRequestId) {
      WebAccel.refreshState = {
        requestId,
        status: result.status,
        running: false,
        reason: WebAccel.refreshState.reason,
        startedAt,
        finishedAt: result.finishedAt
      };
      WebAccel.refreshTask = null;
    }
    return result;
  }

  /** 取消当前全局配置刷新。只终止当前请求，不关闭后续定时刷新。 */
  static cancelConfigRefresh(): boolean {
    return WebAccel.cancelConfigRefreshWithStatus('cancelled');
  }

  /** 取消旧任务并立即创建一条新请求；旧任务结果不能写配置或触发离线包加载。 */
  static restartConfigRefresh(): Promise<ConfigRefreshResult> {
    WebAccel.cancelConfigRefreshWithStatus('superseded');
    return WebAccel.refreshConfig({ reason: 'restart' });
  }

  static getConfigRefreshState(): ConfigRefreshState {
    return {
      requestId: WebAccel.refreshState.requestId,
      status: WebAccel.refreshState.status,
      running: WebAccel.refreshState.running,
      reason: WebAccel.refreshState.reason,
      startedAt: WebAccel.refreshState.startedAt,
      finishedAt: WebAccel.refreshState.finishedAt
    };
  }

  private static cancelConfigRefreshWithStatus(status: string): boolean {
    if (WebAccel.refreshTask === null || !WebAccel.refreshState.running) {
      return false;
    }
    const requestId: number = WebAccel.activeRefreshRequestId;
    remoteConfig.cancelRefresh(requestId, status);
    WebAccel.activeRefreshRequestId = ++WebAccel.refreshRequestSequence;
    WebAccel.refreshState = {
      requestId,
      status,
      running: false,
      reason: WebAccel.refreshState.reason,
      startedAt: WebAccel.refreshState.startedAt,
      finishedAt: Date.now()
    };
    WebAccel.refreshTask = null;
    return true;
  }

  /** 缓存统计快照(调试用) */
  static stats(): CacheStats {
    return webCache.stats();
  }

  /**
   * 调试浮窗开关。开启后,WebAccelView(及 WebAccelLauncher 内的网页)右上角叠加一个浮窗,
   * 实时显示「缓存命中(命中/透传)」与「后台是否在偷偷缓存(下载中/待回填/离线包队列)」。默认关。
   * 用全局 AppStorage('webaccel_debug') 驱动,可在任意处调用、随时开关。
   */
  static setDebug(on: boolean): void {
    AppStorage.setOrCreate<boolean>('webaccel_debug', on);
  }

  /** 调试浮窗是否开启 */
  static isDebug(): boolean {
    return AppStorage.get<boolean>('webaccel_debug') === true;
  }

  /** 某站离线包下载进度(无则 null) */
  static bundleProgress(origin: string): BundleProgress | null {
    return webCache.getBundleProgress(origin);
  }

  static isBundleApplied(url: string, bundleVersion: string = ''): boolean {
    return webCache.isBundleApplied(url, bundleVersion);
  }
}
