import { router } from '@kit.ArkUI';
import { webPool, WebNode } from '../webview/WebPreRender';
import { webCache, CacheStats } from '../cache/WebCacheManager';

@Entry
@Component
struct WebPage {
  private node: WebNode | null = null;
  private timerId: number = -1;
  @State firstPaint: boolean = false;
  @State progress: number = 0;
  @State stats: CacheStats = { raw: 0, disk: 0, hitRaw: 0, hitDisk: 0, miss: 0, blocked: 0, bytes: 0 };
  @State showDebug: boolean = true;
  @State expanded: boolean = true;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string>;
    const url: string = params && params['url'] ? params['url'] : '';
    this.node = webPool.obtain(url);
    // 同步初始状态:若预渲染已完成,这里直接就是已绘制,占位立刻消失
    this.firstPaint = this.node.model.firstPaint;
    this.progress = this.node.model.progress;
    this.node.model.notify = () => {
      if (this.node) {
        this.firstPaint = this.node.model.firstPaint;
        this.progress = this.node.model.progress;
      }
    };
    this.timerId = setInterval(() => {
      this.stats = webCache.stats();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.node) {
      this.node.model.notify = null;
    }
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  onBackPress(): boolean {
    if (this.node) {
      try {
        const c = this.node.model.controller;
        if (c.accessBackward()) {
          c.backward();
          return true;
        }
      } catch (e) {
        // controller 尚未 attach
      }
    }
    return false; // 交还系统:从 WebPage 返回 launcher
  }

  @Builder
  DebugBadge() {
    Row() {
      if (this.expanded) {
        Text(`raw:${this.stats.raw} disk:${this.stats.disk}  命中 R:${this.stats.hitRaw} D:${this.stats.hitDisk}  miss:${this.stats.miss}  block:${this.stats.blocked}  ${Math.round(this.stats.bytes / 1024)}KB`)
          .fontSize(10)
          .fontColor(Color.White)
      } else {
        Text('●').fontSize(10).fontColor(Color.White)
      }
    }
    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
    .backgroundColor('rgba(0,0,0,0.55)')
    .borderRadius(10)
    .margin({ top: 6, right: 6 })
    .onClick(() => {
      this.expanded = !this.expanded;
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      if (this.node) {
        NodeContainer(this.node)
          .width('100%')
          .height('100%')
      }

      // 白屏期原生占位:预渲染已完成时不会出现
      if (!this.firstPaint) {
        Column({ space: 14 }) {
          LoadingProgress()
            .width(44)
            .height(44)
            .color('#0A59F7')
          Text('正在加载…')
            .fontSize(13)
            .fontColor('#888888')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#F0F2F5')
      }

      if (this.showDebug) {
        this.DebugBadge()
      }
    }
    .width('100%')
    .height('100%')
  }
}
