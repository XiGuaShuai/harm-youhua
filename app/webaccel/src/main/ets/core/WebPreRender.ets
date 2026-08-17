import { BuilderNode, FrameNode, NodeController, UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WebViewModel, buildWeb } from './WebShared';
import { webCache } from './WebCacheManager';
import { remoteConfig, RemoteApp, remoteAppMatchesRegion, remoteAppRegions } from './RemoteConfig';

const TAG: string = 'WebPool';
const DOMAIN: number = 0x0001;
const wrappedWeb: WrappedBuilder<[WebViewModel]> = wrapBuilder(buildWeb);

/** A Web node created on demand when NodeContainer mounts it. */
export class WebNode extends NodeController {
  private rootNode: BuilderNode<[WebViewModel]> | null = null;
  readonly model: WebViewModel;

  constructor(model: WebViewModel) {
    super();
    this.model = model;
  }

  prebuild(uiContext: UIContext): void {
    if (this.rootNode) {
      return;
    }
    this.rootNode = new BuilderNode(uiContext);
    this.rootNode.build(wrappedWeb, this.model);
  }

  makeNode(uiContext: UIContext): FrameNode | null {
    this.prebuild(uiContext);
    return this.rootNode ? this.rootNode.getFrameNode() : null;
  }
}

/**
 * Keeps Web nodes for the optional SDK UI and coordinates remote offline bundles.
 * Historical off-screen prerender, document SWR and route prefetch are intentionally absent.
 */
export class WebPool {
  private nodes: Map<string, WebNode> = new Map();
  private appsHandlerSet: boolean = false;

  /** Compatibility hook. Nodes now receive UIContext when NodeContainer mounts them. */
  setUIContext(_ctx: UIContext): void {
  }

  bindRemoteConfig(): void {
    if (this.appsHandlerSet) {
      return;
    }
    remoteConfig.setAppsHandler((_apps: RemoteApp[]) => {
      this.loadTopBundles();
    });
    this.appsHandlerSet = true;
  }

  private ensureNode(url: string): WebNode {
    let node: WebNode | undefined = this.nodes.get(url);
    if (!node) {
      node = new WebNode(new WebViewModel(url));
      this.nodes.set(url, node);
    }
    return node;
  }

  prewarm(url: string, _swrDoc: boolean, autoLoadBundle: boolean = false): WebNode {
    const node: WebNode = this.ensureNode(url);
    if (autoLoadBundle) {
      this.loadBundleFor(url);
    }
    return node;
  }

  obtainNoBundle(url: string): WebNode {
    return this.ensureNode(url);
  }

  obtain(url: string, autoLoadBundle: boolean = true): WebNode {
    const node: WebNode = this.ensureNode(url);
    if (autoLoadBundle) {
      this.loadBundleFor(url);
    }
    return node;
  }

  loadBundle(url: string): void {
    this.loadBundleFor(url);
  }

  loadBundleForApp(app: RemoteApp): void {
    this.loadBundleForRemoteApp(app, webCache.getActiveRegion());
  }

  loadTopBundles(): void {
    const apps: RemoteApp[] = remoteConfig.getApps();
    for (let i = 0; i < apps.length; i++) {
      const app: RemoteApp = apps[i];
      if (app && app.bundle === true && app.scope === 'top') {
        this.loadBundleForRemoteApp(app);
      }
    }
  }

  /** 后台配置刷新后,已打开/已创建过的网页也要重新检查离线包版本,覆盖 scope=app 场景。 */
  reloadOpenedBundles(): void {
    this.nodes.forEach((node: WebNode, url: string) => {
      this.loadBundleFor(url);
    });
  }

  switchRegion(region: string): void {
    webCache.switchRegion(region);
    const apps: RemoteApp[] = remoteConfig.getApps();
    for (let i = 0; i < apps.length; i++) {
      const app: RemoteApp = apps[i];
      if (app && app.bundle === true && app.scope === 'region' && remoteAppMatchesRegion(app, region)) {
        this.loadBundleForRemoteApp(app, region);
      }
    }
  }

  private loadBundleFor(url: string): void {
    const apps: RemoteApp[] = remoteConfig.getApps();
    const targetOrigin: string = this.originOf(url);
    const activeRegion: string = webCache.getActiveRegion();
    let matched: RemoteApp | undefined = undefined;
    for (let i = 0; i < apps.length; i++) {
      const app: RemoteApp = apps[i];
      if (app && app.bundle === true && app.url === url && remoteAppMatchesRegion(app, activeRegion)) {
        matched = app;
        break;
      }
    }
    if (!matched && targetOrigin.length > 0) {
      for (let i = 0; i < apps.length; i++) {
        const app: RemoteApp = apps[i];
        if (app && app.bundle === true && this.originOf(app.url) === targetOrigin &&
          remoteAppMatchesRegion(app, activeRegion)) {
          matched = app;
          break;
        }
      }
    }
    if (matched) {
      this.loadBundleForRemoteApp(matched, activeRegion);
    }
  }

  private originOf(url: string): string {
    const match: RegExpMatchArray | null = url ? url.match(/^https?:\/\/[^\/]+/) : null;
    return match ? match[0] : '';
  }

  private loadBundleForRemoteApp(app: RemoteApp, requestedRegion: string = ''): void {
    const server: string = remoteConfig.getServer();
    if (server.length === 0 || !app || app.bundle !== true || !app.url) {
      return;
    }
    const scope: string = app.scope ? app.scope : 'app';
    let ownerRegion: string = '';
    if (scope === 'region') {
      ownerRegion = requestedRegion.length > 0 ? requestedRegion : webCache.getActiveRegion();
      if (!remoteAppMatchesRegion(app, ownerRegion)) {
        hilog.info(DOMAIN, TAG, 'skip region bundle id=%{public}s regions=%{public}s active=%{public}s',
          app.id, remoteAppRegions(app).join(','), ownerRegion);
        return;
      }
    }
    const compressed: boolean = !!app.compressedManifestUrl;
    let manifestUrl: string = compressed
      ? app.compressedManifestUrl as string
      : (app.manifestUrl ? app.manifestUrl : '/bundles/' + app.id + '/manifest.json');
    const version: string = compressed && app.compressedBundleVersion
      ? app.compressedBundleVersion
      : (app.bundleVersion ? app.bundleVersion : '');
    if (!manifestUrl.startsWith('http://') && !manifestUrl.startsWith('https://')) {
      manifestUrl = server + (manifestUrl.startsWith('/') ? manifestUrl : '/' + manifestUrl);
    }
    webCache.loadRemoteBundle(app.url, manifestUrl, version, app.id, ownerRegion, scope,
      app.configJson ? app.configJson : '', !!app.configEnvironment);
  }

  goBack(url: string): boolean {
    const node: WebNode | undefined = this.nodes.get(url);
    if (!node) {
      return false;
    }
    try {
      if (node.model.controller.accessBackward()) {
        node.model.controller.backward();
        return true;
      }
    } catch (e) {
      // The controller may not be attached yet.
    }
    return false;
  }

  release(url: string): void {
    this.nodes.delete(url);
  }
}

export const webPool: WebPool = new WebPool();
