import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { webCache, CacheStats, BundleProgress } from './core/WebCacheManager';
import { webPool, WebNode } from './core/WebPreRender';
import { remoteConfig, RemoteApp, ConfigureOptions } from './core/RemoteConfig';

const TAG: string = 'WebAccel';
const DOMAIN: number = 0x0001;

/**
 * WebAccel.init 入参(继承 ConfigureOptions 的 configServer/apps/blockHosts/settings)。全部可选:
 *  - 只填 configServer → 开机从 admin 后台拉应用列表/黑名单/设置(标准模式);
 *  - 只填 apps        → 不联网,直接用给定列表(纯本地/直连模式,元服务也可这样用);
 *  - 两者都填         → apps 作默认兜底,后台配置拉到后覆盖。
 */
export interface WebAccelOptions extends ConfigureOptions {
  autoRefresh?: boolean;     // 有 configServer 时是否开机异步拉最新配置(默认 true)
}

/**
 * 网页加速 SDK 门面(全静态)。把内核初始化、离线缓存、远程配置、离屏预渲染收成一组调用。
 *
 * 典型接入(3 步):
 *   ① UIAbility.onCreate:   WebAccel.init(this.context, { configServer })
 *   ② 首个页面 aboutToAppear: WebAccel.attach(this.getUIContext()); WebAccel.prewarm(url)
 *   ③ 展示页:                WebAccelView({ url })   // 或自行 NodeContainer(WebAccel.obtain(url))
 *
 * 元服务(Atomic Service)注意:不要打 rawfile 离线包以保持包体 ≤ 2MB,缓存全走运行时沙箱。
 */
export class WebAccel {
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
    webPool.bindRemoteConfig();

    // ⑤ 异步:有后台且允许时拉服务器最新配置,成功后再注入一次
    const autoRefresh: boolean = !(options && options.autoRefresh === false);
    if (autoRefresh) {
      remoteConfig.refresh().then((ok: boolean) => {
        if (ok) {
          webCache.setBlockHosts(remoteConfig.getBlockHosts());
          webCache.applySettings(remoteConfig.getSettings());
          WebAccel.runExploreReports(); // 众包探索:对后台标记的待探索 app 匿名上报本地已缓存资源
        }
      });
    }
    hilog.info(DOMAIN, TAG, 'initialized (server=%{public}s)',
      remoteConfig.getServer().length > 0 ? remoteConfig.getServer() : '(none)');
  }

  // 众包探索上报:对后台标记为待探索(explore)的 app,按采样率上报本地已缓存的静态资源(匿名)
  private static runExploreReports(): void {
    const ex = remoteConfig.getExplore();
    if (ex.apps.length === 0 || ex.sample <= 0) {
      return;
    }
    const server: string = remoteConfig.getServer();
    const apps: RemoteApp[] = remoteConfig.getApps();
    for (let i = 0; i < ex.apps.length; i++) {
      const id: string = ex.apps[i];
      const a: RemoteApp | undefined = apps.find((x: RemoteApp) => x.id === id);
      if (a) {
        const om = a.url.match(/^https?:\/\/[^\/]+/);
        const origin: string = om ? om[0] : '';
        if (origin.length > 0) {
          webCache.reportExploration(a.id, origin, server, ex.sample);
        }
      }
    }
  }

  /** 提供 UIContext(离屏预渲染需要)。在首个页面/组件 aboutToAppear 调用一次 */
  static attach(uiContext: UIContext): void {
    webPool.setUIContext(uiContext);
  }

  /**
   * 预热一个网页:预连接 +(可选)主文档 SWR + 离屏预渲染。通常对列表里每个 URL 调用。
   * @param swrDoc 是否对主文档启用陈旧即用缓存(公开页可开;含登录态的慎开)。默认 true
   */
  static prewarm(url: string, swrDoc: boolean = true): void {
    webPool.prewarm(url, swrDoc);
  }

  /** 取一个已离屏渲染好的节点用于显示(WebAccelView 内部用;也可自行 NodeContainer 挂载) */
  static obtain(url: string): WebNode {
    return webPool.obtain(url);
  }

  /** 该网页能后退则后退,返回是否消费了返回事件。宿主页 onBackPress 里转调即可 */
  static goBack(url: string): boolean {
    return webPool.goBack(url);
  }

  /** 当前应用列表(来自后台 / 缓存 / 直供) */
  static getApps(): RemoteApp[] {
    return remoteConfig.getApps();
  }

  /** 运行时直接喂应用列表(不依赖后台;会写入 AppStorage('apps') 并触发 @StorageLink 刷新) */
  static setApps(apps: RemoteApp[]): void {
    remoteConfig.setApps(apps);
  }

  /** 手动拉一次后台最新配置(成功后自动重注入黑名单/设置)。未配置后台返回 false */
  static async refreshConfig(): Promise<boolean> {
    const ok: boolean = await remoteConfig.refresh();
    if (ok) {
      webCache.setBlockHosts(remoteConfig.getBlockHosts());
      webCache.applySettings(remoteConfig.getSettings());
    }
    return ok;
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
}
