import { BuilderNode, FrameNode, NodeController, UIContext, RenderOptions, Size, display } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WebViewModel, buildWeb } from './WebShared';
import { webCache } from './WebCacheManager';
import { remoteConfig, RemoteApp } from './RemoteConfig';

const TAG: string = 'WebPreRender';
const DOMAIN: number = 0x0001;

// wrapBuilder 只接受全局 @Builder,这里包一次复用
const wrappedWeb: WrappedBuilder<[WebViewModel]> = wrapBuilder(buildWeb);

/**
 * 一个网页的离屏节点:用 BuilderNode 把 Web 建在可见界面之外,提前开始加载/渲染;
 * 真要显示时由 NodeContainer 通过 makeNode 取走这个已经渲染好的节点。
 */
export class WebNode extends NodeController {
  private rootNode: BuilderNode<[WebViewModel]> | null = null;
  private built: boolean = false;
  readonly model: WebViewModel;

  constructor(model: WebViewModel) {
    super();
    this.model = model;
  }

  /** 离屏预构建:挂到 NodeContainer 之前就创建 Web 并开始加载(给定屏幕尺寸以便离屏渲染) */
  prebuild(uiContext: UIContext): void {
    if (this.built) {
      return;
    }
    let size: Size = { width: 1080, height: 2340 };
    try {
      const d = display.getDefaultDisplaySync();
      size = { width: d.width, height: d.height };
    } catch (e) {
      // 取不到就用默认尺寸
    }
    const options: RenderOptions = { selfIdealSize: size };
    this.rootNode = new BuilderNode(uiContext, options);
    this.rootNode.build(wrappedWeb, this.model);
    this.built = true;
    hilog.info(DOMAIN, TAG, 'prebuild %{public}s', this.model.url);
  }

  makeNode(uiContext: UIContext): FrameNode | null {
    if (!this.built) {
      this.prebuild(uiContext);
    }
    return this.rootNode ? this.rootNode.getFrameNode() : null;
  }
}

/**
 * 网页预渲染池:按 URL 复用离屏节点。
 * 在 launcher/上一屏调用 prewarm(url) 提前渲染;打开对应网页时 obtain(url) 拿到已渲染节点,秒显。
 */
export class WebPool {
  private nodes: Map<string, WebNode> = new Map();
  private uiContext: UIContext | null = null;
  private handlerSet: boolean = false;
  private appsHandlerSet: boolean = false;

  /** 提供一个 UIContext(任意页面/窗口的都行,同窗口共享) */
  setUIContext(ctx: UIContext): void {
    this.uiContext = ctx;
    if (!this.handlerSet) {
      // 站点更新被检测到 → 刷新对应节点(离屏/展示中都覆盖),做到最快失效
      webCache.setDocUpdateHandler((url: string) => {
        this.onDocUpdated(url);
      });
      this.handlerSet = true;
    }
    const registered: boolean = this.ensureAppsHandler();
    if (!registered) {
      this.prewarmConfiguredApps(remoteConfig.getApps());
    }
  }

  /** 配置异步刷新后,自动对新下发的应用补预热;launcher 无需自己感知配置时序 */
  bindRemoteConfig(): void {
    this.ensureAppsHandler();
  }

  private ensureAppsHandler(): boolean {
    if (this.appsHandlerSet) {
      return false;
    }
    remoteConfig.setAppsHandler((apps: RemoteApp[]) => {
      this.prewarmConfiguredApps(apps);
    });
    this.appsHandlerSet = true;
    return true;
  }

  // 同时离屏预渲染的应用数上限:只热预前 MAX_EAGER_PRERENDER 个,避免 N 个 Web 同时建抢首屏资源。
  // 其余应用先做轻量预热(预连接 + 离线包预下 + SWR),再分批延迟补离屏预渲染。
  private static readonly MAX_EAGER_PRERENDER: number = 2;
  private static readonly LAZY_PRERENDER_STEP_MS: number = 1200;

  private prewarmConfiguredApps(apps: RemoteApp[]): void {
    if (!apps || apps.length === 0) {
      return;
    }
    let eager: number = 0;
    let lazyDelay: number = 0;
    for (let i = 0; i < apps.length; i++) {
      const app: RemoteApp = apps[i];
      if (!app || !app.url || app.url.length === 0) {
        continue;
      }
      const swr: boolean = app.swrDoc !== false;
      const wantPrerender: boolean = false;

      // 轻量预热:所有应用都做(快、不占渲染线程)—— 预连接 + 离线包预下 + SWR
      // 服务端配置到达后，主动触发所有 bundle:true 站点下载离线包。
      // 只在 source=server 时执行，避免用旧沙箱配置抢先拉过期版本。
      if (remoteConfig.getSource() === 'server' && app.bundle === true) {
        this.loadBundleFor(app.url);
      }
      try {
        webview.WebviewController.prepareForPageLoad(app.url, true, 4);
      } catch (e) {
        const er = e as BusinessError;
        hilog.error(DOMAIN, TAG, 'preconnect failed: %{public}s', er.message);
      }
      // 后台配置的额外预连接域:对该站资源/接口所在的跨域CDN提前做DNS+TLS握手。
      // 通用能力(SDK不认识具体站,域名全由后台 preconnectHosts 下发):JS渲染型站(主文档空、资源在跨域CDN)预连其CDN域可压短白屏。
      this.preconnectHosts(app.preconnectHosts);
      if (swr) {
        webCache.enableDocCache([app.url]);
      }

      // 通用路由预取:对配置了 routes 的站(任何打包器都适用),延迟预拉二级路由页主文档进缓存,
      // 点二级页(如 K11 美食页)时主文档已在本地、秒一截。延迟 2.5s 触发,先让首屏加载完,不抢首屏资源。
      if (app.routes && app.routes.length > 0) {
        const om = app.url.match(/^https?:\/\/[^\/]+/);
        const origin: string = om ? om[0] : '';
        const routes: string[] = app.routes;
        if (origin.length > 0) {
          setTimeout(() => {
            webCache.prefetchRoutes(origin, routes);
          }, 2500);
        }
      }

      if (!wantPrerender) {
        continue;
      }
      if (eager < WebPool.MAX_EAGER_PRERENDER) {
        // 前几个:立即离屏预渲染(集中首屏资源给最可能先点的应用)
        try {
          webview.WebviewController.prepareForPageLoad(app.url, true, 4);
        } catch (e) {
          const er = e as BusinessError;
          hilog.warn(DOMAIN, TAG, 'lazy preconnect failed %{public}s', er.message);
        }
        eager++;
      } else {
        // 其余:延迟分批离屏预渲染,错开避免和首屏抢资源
        lazyDelay += WebPool.LAZY_PRERENDER_STEP_MS;
        const url: string = app.url;
        setTimeout(() => {
          try {
            webview.WebviewController.prepareForPageLoad(url, true, 4);
          } catch (e) {
            const er = e as BusinessError;
            hilog.warn(DOMAIN, TAG, 'lazy preconnect failed %{public}s', er.message);
          }
        }, lazyDelay);
      }
    }
  }

  /**
   * 对后台配置的额外域做预连接(DNS+TLS 握手提前到点击之前)。通用:域名全部来自后台 preconnectHosts,SDK 不硬编码任何站。
   * 接受 'host'、'host:port'、'https://host' 等形式,统一规范成 https://host 再预连;非法/空项跳过。
   */
  private preconnectHosts(hosts: string[] | undefined): void {
    if (!hosts || hosts.length === 0) {
      return;
    }
    for (let i = 0; i < hosts.length; i++) {
      let h: string = (hosts[i] || '').trim();
      if (h.length === 0) {
        continue;
      }
      // 没带协议就补 https://(预连接走 https)
      if (h.indexOf('http://') !== 0 && h.indexOf('https://') !== 0) {
        h = 'https://' + h;
      }
      try {
        webview.WebviewController.prepareForPageLoad(h, true, 2); // socket 数小一点,只为握手预热
        hilog.info(DOMAIN, TAG, 'preconnect host %{public}s', h);
      } catch (e) {
        const er = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'preconnect host failed %{public}s: %{public}s', h, er.message);
      }
    }
  }

  /** 主文档版本变化时刷新对应节点。只在"刚加载完不久"才刷,避免打断用户操作(填表) */
  private onDocUpdated(url: string): void {
    const node: WebNode | undefined = this.nodes.get(url);
    if (node && (Date.now() - node.model.loadedAt) < 20000) {
      try {
        node.model.controller.refresh();
        hilog.info(DOMAIN, TAG, 'refreshed node for new version: %{public}s', url);
      } catch (e) {
        const er = e as BusinessError;
        hilog.error(DOMAIN, TAG, 'refresh failed: %{public}s', er.message);
      }
    }
  }

  /**
   * 预热某个网页:预连接 +(可选)主文档 SWR + 离屏预渲染。
   * @param swrDoc 是否对该网页主文档启用陈旧即用缓存(公开页可开;含登录态的慎开)
   */
  prewarm(url: string, swrDoc: boolean): WebNode {
    let node: WebNode | undefined = this.nodes.get(url);
    if (!node) {
      node = new WebNode(new WebViewModel(url));
      this.nodes.set(url, node);
    }
    // 预热即开始下离线包:让 chunk 尽早进沙箱,等用户点进去时已在本地,不和慢源站抢首屏。
    // (WebCache 内部按 origin 去重,所以这里和 obtain 重复调用都安全)
    this.loadBundleFor(url);
    try {
      webview.WebviewController.prepareForPageLoad(url, true, 4); // 预连接
    } catch (e) {
      const er = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'preconnect failed: %{public}s', er.message);
    }
    if (swrDoc) {
      webCache.enableDocCache([url]);
    }
    if (this.uiContext) {
      node.prebuild(this.uiContext); // 离屏开始加载渲染
    }
    return node;
  }

  /** 查某 url 在远程配置里的 swrDoc(默认 true;显式配 false 的动态站如 bilibili 返回 false,避免给空主文档做SWR) */
  private swrDocFor(url: string): boolean {
    const apps: RemoteApp[] = remoteConfig.getApps();
    for (let i = 0; i < apps.length; i++) {
      if (apps[i] && apps[i].url === url) {
        return apps[i].swrDoc !== false;
      }
    }
    return true;
  }

  /** 显示时获取节点;未预热则即时创建(退化为普通加载) */
  obtain(url: string): WebNode {
    let node: WebNode | undefined = this.nodes.get(url);
    if (!node) {
      node = this.prewarm(url, this.swrDocFor(url)); // 用该站真实 swrDoc(动态站如 bilibili 为 false),不硬塞 true
    }
    this.loadBundleFor(url); // 打开该网页应用时,按需从后台下载它的离线包(WebCache 内部按 origin 去重)
    return node;
  }

  /**
   * 在远程配置里找到该 url 对应的 app,若启用离线包则从后台下载(manifestUrl 没下发就按 id 兜底拼)。
   * 未配置后台地址(纯本地/直连模式)时跳过——元服务保持包体精简、缓存全走运行时沙箱。
   */
  private loadBundleFor(url: string): void {
    const server: string = remoteConfig.getServer();
    if (server.length === 0) {
      return; // 没有后台:不下离线包,靠运行时拦截缓存自愈
    }
    const apps: RemoteApp[] = remoteConfig.getApps();
    for (let i = 0; i < apps.length; i++) {
      const a: RemoteApp = apps[i];
      if (a.url === url && a.bundle === true) {
        // manifestUrl 可能是后台下发的全地址,也可能是相对路径;为空则按 id 兜底拼
        const useCompressed: boolean = a.compressedManifestUrl !== undefined && a.compressedManifestUrl.length > 0;
        let murl: string = useCompressed
          ? (a.compressedManifestUrl as string)
          : ((a.manifestUrl !== undefined && a.manifestUrl.length > 0) ? a.manifestUrl : ('/bundles/' + a.id + '/manifest.json'));
        const version: string = useCompressed && a.compressedBundleVersion !== undefined && a.compressedBundleVersion.length > 0
          ? a.compressedBundleVersion
          : (a.bundleVersion !== undefined ? a.bundleVersion : '');
        if (murl.indexOf('http://') !== 0 && murl.indexOf('https://') !== 0) {
          murl = server + (murl.charAt(0) === '/' ? murl : ('/' + murl));
        }
        webCache.loadRemoteBundle(a.url, murl, version);
        break;
      }
    }
  }

  /** 网页能后退则后退,返回是否消费了返回事件(供宿主页 onBackPress 转调) */
  goBack(url: string): boolean {
    const node: WebNode | undefined = this.nodes.get(url);
    if (node) {
      try {
        const c = node.model.controller;
        if (c.accessBackward()) {
          c.backward();
          return true;
        }
      } catch (e) {
        // controller 尚未 attach
      }
    }
    return false;
  }

  release(url: string): void {
    this.nodes.delete(url);
  }
}

/** 全局单例 */
export const webPool: WebPool = new WebPool();
