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
      }
    })
    .onFirstContentfulPaint(() => {
      model.onPainted();
    })
    .onPageBegin(() => {
      model.onBegin();
    })
    .onPageEnd(() => {
      model.onEnd();
      webCache.flushPending();
      // 页面稳定后,后台把站点全部按需 chunk 预缓存 → 二级页面点进去 JS 已在本地
      setTimeout(() => {
        webCache.prefetchSiteChunks(model.url);
      }, 3000);
    })
}
