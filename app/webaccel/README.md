# webaccel —— 网页应用加速 SDK(HAR)

把「网页应用集合」的多层加速能力(**离线缓存 / 请求拦截 / 离屏预渲染 / chunk 预取 / 远程配置**)封装成一个鸿蒙 HAR 静态共享包,供 App 或 **元服务(Atomic Service)** 以几行代码接入。

> 注:字节码注入(`injectOfflineResources`)被元服务平台禁用,本 SDK 已移除该层;其余加速层照常工作。

> 由原独立 App(`entry`)抽取而来。核心实现见 `src/main/ets/core/`,对外 API 见 `src/main/ets/WebAccel.ets` 与 `WebAccelView.ets`。

## 对外 API

```ts
import { WebAccel, WebAccelLauncher, WebAccelView, WebAccelOptions, RemoteApp } from 'webaccel';
```

| API | 说明 |
|---|---|
| **`WebAccelLauncher({ title?, accentColor? })`** | **开箱即用整页组件**:配置驱动的应用列表 + 内置导航 + 网页展示 + 返回 + 自动预热。配 `init` 即成完整 App |
| `WebAccel.init(context, options?)` | 开机初始化(UIAbility.onCreate 调一次):内核 + 离线缓存 + 配置一把梭 |
| `WebAccelView({ url })` | 加速网页展示组件:节点挂载 + 白屏占位 + 离线进度条(自定义壳时用) |
| `WebAccel.goBack(url)` | 网页能后退则后退,宿主页 `onBackPress` 转调 |
| `WebAccel.getApps()` / `setApps(apps)` | 读 / 运行时直接喂应用列表 |
| `WebAccel.refreshConfig()` | 手动拉一次后台最新配置 |
| `WebAccel.stats()` / `bundleProgress(origin)` | 缓存统计 / 某站离线包进度(调试) |
| **`WebAccel.setDebug(on)`** | **调试浮窗开关**:开后挂在**最顶层**的可拖动浮窗(默认左上角),**首页列表 + 网页全程可见**,实时显示「缓存命中(命中/透传/拦截)」+「后台是否在偷偷缓存(下载中/待回填/离线包队列)」。点击展开收起、拖动移动。默认关,上线别开 |
| `WebAccel.attach(uiContext)` / `prewarm(url, swrDoc?)` / `obtain(url)` | 可选/底层:UIContext 与预热现已自动,通常无需手动调 |

### `WebAccelOptions`

```ts
interface WebAccelOptions {
  configServer?: string;     // admin 后台地址。不填 = 用 SDK 自带默认(见下「后台地址」);传了则覆盖
  apps?: RemoteApp[];        // 兜底/直供应用列表(后台拉到后覆盖;后台不可达时用它)
  blockHosts?: string[];     // 过滤黑名单(覆盖默认内置)
  settings?: RemoteSettings; // 缓存上限 / 校验节流 / 全站预取(bytecodeCache 字段在元服务被忽略)
  autoRefresh?: boolean;     // 是否开机异步拉最新(默认 true)
}
```

## 后台地址(SDK 自带,按 debug/release 自动切换)

后台地址**内置在 SDK** 里、不用接入方写:`webaccel/build-profile.json5` 的 `buildProfileFields.CONFIG_SERVER`,
debug/release 各一个值,`RemoteConfig` 读 `BuildProfile.CONFIG_SERVER` 作默认。

```json5
// webaccel/build-profile.json5
"buildOption":    { "arkOptions": { "buildProfileFields": { "CONFIG_SERVER": "http://192.168.x.x:8787" } } }, // debug:局域网
"buildOptionSet": [{ "name": "release", "arkOptions": { "buildProfileFields": { "CONFIG_SERVER": "https://admin.你的域名.com" } } }] // release:生产
```

> **上线唯一要做的一次性配置**:把 release 那行换成你的真实生产域名(改配置、非代码)。之后切 release 构建,地址自动是生产。
> 想运行时覆盖(多后台)仍可:`WebAccel.init(ctx, { configServer })`。

## 开箱即用(推荐):两步,几乎不写代码

**1) 依赖**(接入方 `oh-package.json5`):`{ "dependencies": { "webaccel": "file:../webaccel" } }`

**2) 一行 init + 一个组件**(连后台地址都不用写):

```ts
// EntryAbility.ets / onCreate —— 唯一的初始化(地址由 SDK 自带)
WebAccel.init(this.context);
// 可选传兜底列表(后台拉不到时也有得显示):WebAccel.init(this.context, { apps: [...] });

// 入口页 Index.ets —— 整个 App 就这一个组件(@Entry 的 build 根需是容器,故包一层 Stack)
@Entry @Component struct Index {
  build() { Stack() { WebAccelLauncher() }.width('100%').height('100%') }
}
```

列表(来自远程配置)、点开秒显、内置导航、离线进度、返回键、全站预热——**全在 `WebAccelLauncher` 内部**,无需 `attach` / `prewarm` 循环 / 自己写网页页 / 注册第二个路由。
可选定制:`WebAccelLauncher({ title: '...', accentColor: '#...' })`。

## 自定义壳(可选):想用自己的列表/页面

不想用内置 launcher,就用低层 API 自己拼:

```ts
WebAccel.init(this.context)                                // onCreate,后台地址 SDK 自带
const apps = WebAccel.getApps()                            // 取列表自己渲染
WebAccelView({ url })                                      // 展示页:加速网页组件
onBackPress(): boolean { return WebAccel.goBack(url) }     // 返回键
```
低层用法下 `WebAccelView` 会自动注入 UIContext,配置就绪即自动预热,通常也无需手动 `attach`/`prewarm`(它们仍作为可选 API 保留)。

应用列表也可用 `@StorageLink('apps') apps: RemoteApp[]` 自动响应——SDK 拉到/直供配置时会写入 `AppStorage('apps')`。

## 元服务(Atomic Service)接入注意

元服务对包体有硬限制:**单包 ≤ 2MB、总计 ≤ 10MB**。本 SDK 为此设计:

1. **不要打 rawfile 内置离线包**。离线缓存全部在运行时下载进沙箱(`filesDir`),**不计入包体**。SDK 编译产物很小,并入元服务 HAP 远低于 2MB。
2. 接入方 `AppScope/app.json5` 设 `"bundleType": "atomicService"`;`entry/src/main/module.json5` 设 `"installationFree": true`,并声明 `ohos.permission.INTERNET` 权限。
3. 缓存来源:
   - 配 `configServer` → 开机拉配置,打开网页应用时按需从后台下载该站离线包(省流量);
   - 不配 `configServer`(纯 `apps` 直供)→ 不下离线包,靠运行时请求拦截缓存自愈(首次稍慢,越用越快)。
4. Web 组件、`BuilderNode` 离屏预渲染在元服务中均可用。

## 打包

```bash
# 单独产出 HAR(供分发):
hvigorw assembleHar -p module=webaccel@default
# 产物:webaccel/build/default/outputs/default/webaccel.har
```

接入示例见同仓库 `../entry` —— 它本身就是消费本 SDK 的**元服务**(`AppScope/app.json5` 已设 `bundleType: atomicService`,`entry/src/main/module.json5` 已设 `installationFree: true`)。
