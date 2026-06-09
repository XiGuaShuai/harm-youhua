import { WebAccel } from './WebAccel';
import { WebAccelView } from './WebAccelView';
import { WebAccelDebugBadge } from './WebAccelDebugBadge';
import { RemoteApp } from './core/RemoteConfig';

/**
 * 开箱即用的「网页应用集合」组件。接入方只需:
 *   ① EntryAbility.onCreate: WebAccel.init(this.context, { configServer })
 *   ② 入口页:               @Entry struct Index { build() { WebAccelLauncher() } }
 *
 * 内部全包办:读远程配置的应用列表 → 渲染 → 内置 Navigation 跳转 → WebAccelView 展示
 * → 离线进度 → 系统返回(网页内先后退,到顶退回列表)。挂载即自动注入 UIContext 并预热全部应用。
 *
 * 想要自定义壳的接入方可改用低层 API:WebAccel.getApps() + WebAccelView({url}) + WebAccel.goBack(url)。
 */
@Component
export struct WebAccelLauncher {
  /** 顶部标题 */
  @Prop title: string = '网页应用';
  /** 列表按钮主色 */
  @Prop accentColor: string = '#0A59F7';
  /** 背景色 */
  @Prop backgroundColor2: string = '#F0F2F5';

  // 应用列表来自远程配置(WebAccel.init 后写入 AppStorage('apps'));拉到新配置自动刷新
  @StorageLink('apps') apps: RemoteApp[] = [];
  // 调试浮窗开关(WebAccel.setDebug 驱动):开后浮窗挂在最顶层,首页列表 + 网页全程可见、可拖动
  @StorageLink('webaccel_debug') debugOn: boolean = false;
  private stack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    // 组件天生有 UIContext:挂载即注入 → 自动对配置里所有应用预热(预连接+预下离线包+离屏预渲染)
    // 接入方无需手动 attach / prewarm。
    WebAccel.attach(this.getUIContext());
  }

  // 网页展示目的页:点列表项后由 Navigation 压栈进入,name = 网页 URL
  @Builder
  webDestination(name: string) {
    NavDestination() {
      WebAccelView({ url: name })
    }
    .hideTitleBar(true)
    .onBackPressed(() => {
      // 网页能后退则先后退(返回 true 消费);到顶层返回 false,交 Navigation 出栈回列表
      return WebAccel.goBack(name);
    })
  }

  build() {
    // 根 Stack:Navigation 在下,调试浮窗在最上层(故首页列表 + 网页页全程可见、可拖动)
    Stack() {
      Navigation(this.stack) {
        Column({ space: 14 }) {
          Text(this.title)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .margin({ top: 48, bottom: 16 })
          ForEach(this.apps, (a: RemoteApp) => {
            Button(a.name)
              .width('80%')
              .height(50)
              .fontSize(16)
              .backgroundColor(this.accentColor)
              .onClick(() => {
                this.stack.pushPath({ name: a.url });
              })
          }, (a: RemoteApp) => a.url)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.backgroundColor2)
      }
      .navDestination(this.webDestination)
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)

      // 调试浮窗:挂在最顶层,首页 + 网页全程可见、可拖动(WebAccel.setDebug(true) 开启)
      if (this.debugOn) {
        WebAccelDebugBadge()
      }
    }
    .width('100%')
    .height('100%')
  }
}
