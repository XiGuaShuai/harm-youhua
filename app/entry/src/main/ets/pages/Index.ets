import { WebAccelLauncher } from 'webaccel';

// 开箱即用:整个「网页应用集合」就这一个组件。
// 列表/网页展示/导航/返回/预热全由 SDK 内部包办;应用列表来自后台远程配置。
// (@Entry 的 build 根节点必须是容器,故用 Stack 包一层)
@Entry
@Component
struct Index {
  build() {
    Stack() {
      WebAccelLauncher()
    }
    .width('100%')
    .height('100%')
  }
}
