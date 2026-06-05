import { BuilderNode, FrameNode, NodeController, UIContext, RenderOptions, Size, display } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WebViewModel, buildWeb, injectOffline } from './WebShared';
import { webCache } from '../cache/WebCacheManager';
import { remoteConfig, CONFIG_SERVER, RemoteApp } from '../config/RemoteConfig';

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

  /** 提供一个 UIContext(任意页面/窗口的都行,同窗口共享) */
  setUIContext(ctx: UIContext): void {
    this.uiContext = ctx;
    if (!this.handlerSet) {
      // 站点更新被检测到 → 刷新对应节点(离屏/展示中都覆盖),做到最快失效
      webCache.setDocUpdateHandler((url: string) => {
        this.onDocUpdated(url);
      });
      // 远程离线包下载完 → 对该站已建节点补注入字节码(下次加载/二级导航即用上)
      webCache.setBundleReadyHandler((origin: string) => {
        this.reinjectOrigin(origin);
      });
      this.handlerSet = true;
    }
  }

  /** 远程离线包就绪后,对该 origin 的已建节点补注入字节码资源 */
  private reinjectOrigin(origin: string): void {
    this.nodes.forEach((node: WebNode, url: string) => {
      if (url.indexOf(origin) === 0) {
        try {
          injectOffline(node.model.controller, url);
          hilog.info(DOMAIN, TAG, 'reinjected offline JS for %{public}s', url);
        } catch (e) {
          // controller 尚未 attach,忽略
        }
      }
    });
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

  /** 显示时获取节点;未预热则即时创建(退化为普通加载) */
  obtain(url: string): WebNode {
    let node: WebNode | undefined = this.nodes.get(url);
    if (!node) {
      node = this.prewarm(url, true);
    }
    this.loadBundleFor(url); // 打开该网页应用时,按需从后台下载它的离线包(WebCache 内部按 origin 去重)
    return node;
  }

  /** 在远程配置里找到该 url 对应的 app,若启用离线包则从后台下载(manifestUrl 没下发就按 id 兜底拼) */
  private loadBundleFor(url: string): void {
    const apps: RemoteApp[] = remoteConfig.getApps();
    for (let i = 0; i < apps.length; i++) {
      const a: RemoteApp = apps[i];
      if (a.url === url && a.bundle === true) {
        const path: string = (a.manifestUrl !== undefined && a.manifestUrl.length > 0)
          ? a.manifestUrl
          : ('/bundles/' + a.id + '/manifest.json');
        webCache.loadRemoteBundle(a.url, CONFIG_SERVER + path);
        break;
      }
    }
  }

  release(url: string): void {
    this.nodes.delete(url);
  }
}

/** 全局单例 */
export const webPool: WebPool = new WebPool();
