import { webCache, CacheStats, BundleProgress } from './core/WebCacheManager';
import { RemoteApp } from './core/RemoteConfig';

/**
 * 可拖动的调试浮窗:显示「缓存命中」+「各应用已缓存/总缓存」。
 * 默认左上角,可拖到任意位置,点击展开/收起。
 * 由 WebAccelLauncher 挂在最顶层(覆盖首页列表 + 网页,全程可见);也可自行挂到页面根。
 * 显隐由 WebAccel.setDebug() 控制(父层渲染门控)。
 */
@Component
export struct WebAccelDebugBadge {
  @State stats: CacheStats = {
    raw: 0, disk: 0, hitRaw: 0, hitDisk: 0, miss: 0, blocked: 0, bytes: 0,
    inflight: 0, pending: 0, bundleActive: 0, bundleQueued: 0, lastUrl: '', recent: [], caching: false
  };
  // 应用列表(WebAccel 写入 AppStorage('apps'))
  @StorageLink('apps') apps: RemoteApp[] = [];
  // 配置来源 / 版本(RemoteConfig 写入 AppStorage):订阅后拉到配置即自动重绘,无需点击浮窗
  @StorageLink('configSource') cfgSource: string = 'fallback';
  @StorageLink('configVersion') cfgVersion: string = '';
  @State expanded: boolean = true;
  @State posX: number = 12;   // 默认左上角
  @State posY: number = 60;
  // 各应用缓存进度文本快照:定时器每秒重算并赋新数组 → 行内 Text 实时重绘
  @State progress: string[] = [];
  private startX: number = 0;
  private startY: number = 0;
  private timerId: number = -1;

  aboutToAppear(): void {
    // 1s 刷新:统计 + 各应用缓存进度(build 重跑时 progressText 读最新值)
    this.timerId = setInterval(() => {
      this.stats = webCache.stats();
      // 每秒重算各应用进度并赋新数组,触发行内 Text 重绘(progressText 读外部 webCache,不被 @State 跟踪)
      this.progress = this.apps.map((a: RemoteApp): string => this.progressText(a));
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /** 后台是否"真的还在缓存"(最近 3 秒内有缓存成功;挂死/卡住的请求不算,避免一直显示"缓存中") */
  private bgCaching(): boolean {
    return this.stats.caching;
  }

  private originOf(url: string): string {
    const om = url.match(/^https?:\/\/[^\/]+/);
    return om ? om[0] : '';
  }

  /** 配置(含应用名)来自哪:服务器 / 缓存 / 兜底 —— 看应用名是不是后台下发的 */
  private configLine(): string {
    const s: string = this.cfgSource; // 读 @StorageLink → 该文本节点随配置来源变化自动重绘
    if (s === 'server') {
      const v: string = this.cfgVersion;
      return '配置: 服务器 ✓ ' + (v.length >= 16 ? v.substring(5, 16) : v);
    }
    if (s === 'cache') {
      return '配置: 缓存(上次后台)';
    }
    return '配置: 兜底(未连后台)';
  }

  private configFromServer(): boolean {
    return this.cfgSource === 'server';
  }

  /**
   * 某应用的缓存进度。两种模式标清楚:
   *  - 启用离线包(bundle:true) → 「包 已下/总数」,有明确总数;
   *  - 未启用(bundle:false)  → 「缓 已缓存条数」,运行时边用边缓存,无固定总数。
   */
  private progressText(app: RemoteApp): string {
    const origin: string = this.originOf(app.url);
    const bp: BundleProgress | null = webCache.getBundleProgress(origin);
    if (bp && bp.total > 0) {
      return `包 ${bp.done}/${bp.total}`;
    }
    return `缓 ${webCache.cachedCountForOrigin(origin)} 条`;
  }

  build() {
    Column() {
      if (this.expanded) {
        Text(this.configLine())
          .fontSize(9)
          .fontColor(this.configFromServer() ? '#22DD88' : '#FFAA55')
        Text(`命中 R:${this.stats.hitRaw} D:${this.stats.hitDisk}　透传:${this.stats.miss}　拦:${this.stats.blocked}`)
          .fontSize(10)
          .fontColor(Color.White)
          .margin({ top: 2 })
        Text(this.bgCaching() ? '↓ 后台缓存中  应用(已缓存/总缓存)' : '后台空闲  应用(已缓存/总缓存)')
          .fontSize(9)
          .fontColor(this.bgCaching() ? '#22DD88' : '#AAAAAA')
          .margin({ top: 2 })
        ForEach(this.apps, (app: RemoteApp, idx: number) => {
          Row() {
            Text(app.name)
              .fontSize(10)
              .fontColor(Color.White)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(idx < this.progress.length ? this.progress[idx] : this.progressText(app))
              .fontSize(10)
              .fontColor('#88CCFF')
              .margin({ left: 8 })
          }
          .width(196)
          .margin({ top: 1 })
          // 进度文本取自 @State progress(定时器每秒刷新);key 用稳定的 url,内容随 @State 实时重绘
        }, (app: RemoteApp) => app.url)
        Text(`沙箱 ${this.stats.disk} 条　${Math.round(this.stats.bytes / 1024)} KB`)
          .fontSize(10)
          .fontColor(Color.White)
          .margin({ top: 2 })
      } else {
        Text('●')
          .fontSize(13)
          .fontColor(this.bgCaching() ? '#22DD88' : Color.White)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .backgroundColor('rgba(0,0,0,0.66)')
    .borderRadius(8)
    .position({ x: this.posX, y: this.posY })
    .onClick(() => {
      this.expanded = !this.expanded;
    })
    .gesture(
      PanGesture()
        .onActionStart(() => {
          this.startX = this.posX;
          this.startY = this.posY;
        })
        .onActionUpdate((e: GestureEvent) => {
          this.posX = this.startX + e.offsetX;
          this.posY = this.startY + e.offsetY;
        })
    )
  }
}
