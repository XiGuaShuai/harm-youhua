import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webCache } from './WebCacheManager';

const TAG: string = 'WebPerf';
const DOMAIN: number = 0x0001;
// 注:字节码注入(injectOfflineResources)在元服务中被平台禁用,已移除;
// 其余加速层(离线缓存拦截 / 主文档 SWR / 离屏预渲染 / chunk 预取 / 黑名单短路)照常工作。

/**
 * 一个网页实例的状态 + 配置。在离屏预渲染和页面展示之间共享同一个对象,
 * Web 的回调更新这里的字段,并通过 notify 通知正在展示它的页面刷新。
 */
export class WebViewModel {
  url: string;
  controller: webview.WebviewController;
  progress: number;
  firstPaint: boolean;
  loading: boolean;
  loadedAt: number;            // 最近一次加载完成时间(供"刚加载完才自动刷新"判断)
  notify: (() => void) | null; // 展示页注册:状态变化时刷新 UI

  constructor(url: string) {
    this.url = url;
    this.controller = new webview.WebviewController();
    this.progress = 0;
    this.firstPaint = false;
    this.loading = true;
    this.loadedAt = 0;
    this.notify = null;
  }

  private fire(): void {
    if (this.notify) {
      this.notify();
    }
  }

  onProgress(p: number): void {
    this.progress = p;
    this.fire();
  }

  onPainted(): void {
    if (!this.firstPaint) {
      this.firstPaint = true;
      hilog.info(DOMAIN, TAG, 'FCP %{public}s', this.url);
    }
    this.fire();
  }

  onBegin(): void {
    this.loading = true;
    this.fire();
  }

  onEnd(): void {
    this.loading = false;
    this.firstPaint = true;
    this.loadedAt = Date.now();
    hilog.info(DOMAIN, TAG, 'onPageEnd %{public}s', this.url);
    this.fire();
  }
}

/**
 * 全局 @Builder:所有网页统一的 Web 配置。
 * 离线缓存拦截、Google 短路、加载回调都集中在这里 —— 加新网页无需重复配置。
 */
@Builder
export function buildWeb(model: WebViewModel) {
  Web({ src: model.url, controller: model.controller })
    .cacheMode(CacheMode.Default)
    .domStorageAccess(true)
    .databaseAccess(true)
    .fileAccess(true)
    .imageAccess(true)
    .onlineImageAccess(true)
    .javaScriptAccess(true)
    .mixedMode(MixedMode.All)
    .zoomAccess(true)
    .geolocationAccess(true)
    .width('100%')
    .height('100%')
    // 网页请求定位(如 Booking"当前位置搜索")时授权给网页 → 网页能拿到位置才能搜。
    // 元服务本身的系统定位权限在 EntryAbility 启动时申请(见 EntryAbility.ets)。
    .onGeolocationShow((event) => {
      if (event) {
        event.geolocation.invoke(event.origin, true, false); // 允许该 origin 使用定位,不永久保存
      }
    })
    .onInterceptRequest((event) => {
      try {
        const req = event.request;
        return webCache.intercept(req.getRequestUrl(), req.getRequestMethod(), req.getRequestHeader());
      } catch (e) {
        return null;
      }
    })
    .onProgressChange((event) => {
      if (event) {
        model.onProgress(event.newProgress);
        // 秒开关键:动态 SPA 站 FCP 触发晚甚至不触发,占位就会傻等到 onPageEnd 才消失(多停几秒)。
        // 进度到 85% 才主动消占位(留足 CSS 加载时间,避免过早露出无样式中间态);仍比傻等 onPageEnd 快很多。
        // onPainted 内部去重,不会重复触发。优先还是靠真实 FCP 回调消位(见下),这里只是兜底。
        if (event.newProgress >= 85 && !model.firstPaint) {
          model.onPainted();
        }
      }
    })
    .onFirstContentfulPaint(() => {
      model.onPainted();
      // 首屏内容已绘制 → 立即后台预取二级 chunk(比等 onPageEnd+3s 提前约 2.5s,翻页更跟手)。
      // prefetchSiteChunks 内部按 origin 去重,重复调用无副作用。
      webCache.prefetchSiteChunks(model.url);
    })
    .onPageBegin(() => {
      model.onBegin();
      // 注:曾在此注入脚本隐藏网站自身 loading 元素,但 [class*=loading]/[splash] 模糊匹配会误伤
      // 正常的大面积内容容器(轮播/banner/lazy-loading 包裹层)→ 三个站均出现排版错乱,故移除。
      // "loading 滞后"改由更安全的方式治理:占位绑 FCP / 进度阈值消位(见 onProgressChange),不碰页面 DOM。
    })
    .onPageEnd(() => {
      model.onEnd();
      webCache.flushPending();
      // 兜底:个别站不触发 FCP 时,页面稳定后短延迟再预取一次(已缓存的会被去重跳过)
      setTimeout(() => {
        webCache.prefetchSiteChunks(model.url);
      }, 800);
    })
}
