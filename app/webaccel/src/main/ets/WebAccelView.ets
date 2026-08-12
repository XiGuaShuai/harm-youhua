import { webPool, WebNode } from './core/WebPreRender';
import { webCache, BundleProgress } from './core/WebCacheManager';

/**
 * 开箱即用的加速网页展示组件。内部按需创建 Web 节点并由 NodeContainer 挂载;
 * 首屏前显示白屏占位,离线包下载时显示底部进度条(下完自动消失)。
 *
 * 用法(宿主页只需一行):
 *   WebAccelView({ url: this.url })
 *
 * 后退处理放在宿主页(NodeController 节点在本组件内):
 *   onBackPress(): boolean { return WebAccel.goBack(this.url); }
 */
@Component
export struct WebAccelView {
  /** 要展示的网页 URL。 */
  url: string = '';
  /** 是否显示底部「离线加速准备中 x/y」进度条 */
  @Prop showBundleProgress: boolean = true;
  /** 是否在首屏绘制前显示原生占位。 */
  @Prop showPlaceholder: boolean = true;
  /** 占位背景色 */
  @Prop placeholderColor: string = '#F0F2F5';
  @Prop autoLoadBundle: boolean = true;

  private node: WebNode | null = null;
  private timerId: number = -1;
  private origin: string = '';
  @State firstPaint: boolean = false;
  @State bundleTotal: number = 0;
  @State bundleDone: number = 0;
  // 进度条"自动收起":避免个别离线包资源下载失败(如政府站某些资源 401/超时)导致 done 永远追不上 total、进度条无限转圈。
  @State bundleHidden: boolean = false;
  private bundleElapsed: number = 0;     // 进度条已显示秒数
  private bundleLastDone: number = -1;   // 上次的 done,用于判断"是否还在推进"
  private bundleStallSec: number = 0;    // 连续无新进展的秒数

  aboutToAppear(): void {
    // 组件自带 UIContext:自动注入,低层(不经 WebAccelLauncher)用法也无需接入方手动 attach
    webPool.setUIContext(this.getUIContext());
    const om = this.url.match(/^https?:\/\/[^\/]+/);
    this.origin = om ? om[0] : '';
    this.node = this.autoLoadBundle ? webPool.obtain(this.url) : webPool.obtainNoBundle(this.url);
    // 同步首屏状态，FCP/进度回调会通知组件收起占位。
    this.firstPaint = this.node.model.firstPaint;
    this.node.model.notify = () => {
      if (this.node) {
        this.firstPaint = this.node.model.firstPaint;
      }
    };
    if (this.showBundleProgress) {
      this.timerId = setInterval(() => {
        const bp: BundleProgress | null = webCache.getBundleProgress(this.origin);
        if (bp) {
          this.bundleTotal = bp.total;
          this.bundleDone = bp.done;
          // 下完 → 标记隐藏(下面 build 条件也会隐藏)
          if (bp.total > 0 && bp.done >= bp.total) {
            this.bundleHidden = true;
          }
          // 防无限转圈:① 总显示超过 12s ② 连续 6s 无新进展(有资源下载失败卡住)→ 自动收起进度条。
          // 资源仍会在后台继续/重试,只是不再用转圈打扰用户。
          this.bundleElapsed++;
          if (bp.done === this.bundleLastDone) {
            this.bundleStallSec++;
          } else {
            this.bundleStallSec = 0;
            this.bundleLastDone = bp.done;
          }
          if (this.bundleElapsed >= 12 || this.bundleStallSec >= 6) {
            this.bundleHidden = true;
          }
        }
      }, 1000);
    }
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

  // 离线加速进度条:底部居中,下完自动消失;不拦截网页交互
  @Builder
  BundleBadge() {
    Column() {
      Row() {
        LoadingProgress()
          .width(14)
          .height(14)
          .color(Color.White)
        Text(`离线加速准备中 ${this.bundleDone}/${this.bundleTotal}`)
          .fontSize(11)
          .fontColor(Color.White)
          .margin({ left: 6 })
      }
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor('rgba(10,89,247,0.88)')
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .padding({ bottom: 40 })
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      if (this.node) {
        NodeContainer(this.node)
          .width('100%')
          .height('100%')
      }

      // 白屏期原生占位
      if (this.showPlaceholder && !this.firstPaint) {
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
        .backgroundColor(this.placeholderColor)
      }

      // 离线包正在下载时显示进度;下完 / 超时 / 长时间无进展(个别资源失败)→ 自动收起,不无限转圈
      if (this.showBundleProgress && !this.bundleHidden && this.bundleTotal > 0 && this.bundleDone < this.bundleTotal) {
        this.BundleBadge()
      }
    }
    .width('100%')
    .height('100%')
  }
}
