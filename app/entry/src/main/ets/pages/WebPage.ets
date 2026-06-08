import { WebAccel, WebAccelView } from 'webaccel';

@Entry
@Component
struct WebPage {
  private url: string = '';

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, string>;
    this.url = params && params['url'] ? params['url'] : '';
  }

  onBackPress(): boolean {
    // 网页能后退则先后退;到顶层再交还系统(返回 launcher)
    return WebAccel.goBack(this.url);
  }

  build() {
    // @Entry 的 build 根节点必须是容器组件,故用 Stack 包一层 SDK 组件
    Stack() {
      // 开箱即用:节点挂载 + 白屏占位 + 离线加速进度条,全在 SDK 组件里
      WebAccelView({ url: this.url })
    }
    .width('100%')
    .height('100%')
  }
}
