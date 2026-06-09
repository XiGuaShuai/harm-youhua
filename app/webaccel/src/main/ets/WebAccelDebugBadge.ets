import { webCache, CacheStats } from './core/WebCacheManager';
import { remoteConfig, RemoteApp } from './core/RemoteConfig';

/**
 * 可拖动的调试浮窗:实时显示「缓存命中」+「后台是否在偷偷缓存」。
 * 默认左上角,可拖到任意位置,点击展开/收起。
 * 由 WebAccelLauncher 挂在最顶层(覆盖首页列表 + 网页,全程可见);
 * 自定义壳也可自行 WebAccelDebugBadge() 挂到页面根。显隐由 WebAccel.setDebug() 控制(父层渲染门控)。
 */
@Component
export struct WebAccelDebugBadge {
  @State stats: CacheStats = {
    raw: 0, disk: 0, hitRaw: 0, hitDisk: 0, miss: 0, blocked: 0, bytes: 0,
    inflight: 0, pending: 0, bundleActive: 0, bundleQueued: 0, lastUrl: ''
  };
  @State expanded: boolean = true;
  @State posX: number = 12;   // 默认左上角
  @State posY: number = 60;
  private startX: number = 0;
  private startY: number = 0;
  private timerId: number = -1;

  aboutToAppear(): void {
    this.timerId = setInterval(() => {
      this.stats = webCache.stats();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /** 后台是否正在偷偷缓存(下载回填 / 待回填 / 离线包下载) */
  private bgCaching(): boolean {
    return (this.stats.inflight + this.stats.pending + this.stats.bundleActive + this.stats.bundleQueued) > 0;
  }

  /** 最近缓存的资源属于哪个应用/站点 + 文件名(看"在缓存哪个应用的资源") */
  private cachingLabel(): string {
    const u: string = this.stats.lastUrl;
    if (u.length === 0) {
      return '';
    }
    const om = u.match(/^https?:\/\/[^\/]+/);
    const origin: string = om ? om[0] : '';
    const host: string = origin.replace(/^https?:\/\//, '');
    const path: string = u.split('?')[0];
    const slash: number = path.lastIndexOf('/');
    const file: string = slash >= 0 ? path.substring(slash + 1) : path;
    // 能匹配到应用就显示应用名,否则显示域名
    let name: string = host;
    const apps: RemoteApp[] = remoteConfig.getApps();
    for (let i = 0; i < apps.length; i++) {
      if (apps[i].url && origin.length > 0 && apps[i].url.indexOf(origin) === 0) {
        name = apps[i].name;
        break;
      }
    }
    return file.length > 0 ? `${name} · ${file}` : name;
  }

  build() {
    Column() {
      if (this.expanded) {
        Text(`命中 R:${this.stats.hitRaw} D:${this.stats.hitDisk}　透传:${this.stats.miss}　拦:${this.stats.blocked}`)
          .fontSize(10)
          .fontColor(Color.White)
        Text(this.bgCaching()
          ? `↓ 后台缓存中  下载:${this.stats.inflight} 待:${this.stats.pending} 包:${this.stats.bundleActive}+${this.stats.bundleQueued}`
          : '后台空闲')
          .fontSize(10)
          .fontColor(this.bgCaching() ? '#22DD88' : '#AAAAAA')
          .margin({ top: 2 })
        if (this.stats.lastUrl.length > 0) {
          Text(this.cachingLabel())
            .fontSize(9)
            .fontColor('#88CCFF')
            .margin({ top: 1 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 240 })
        }
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
