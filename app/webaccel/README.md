# webaccel —— 网页应用加速 SDK(HAR)

把「网页应用集合」的多层加速能力(**离线缓存 / 请求拦截 / 离屏预渲染 / chunk 预取 / 远程配置**)封装成一个鸿蒙 HAR 静态共享包,供 App 或 **元服务(Atomic Service)** 以几行代码接入。

> 注:字节码注入(`injectOfflineResources`)被元服务平台禁用,本 SDK 已移除该层;其余加速层照常工作。

> 由原独立 App(`entry`)抽取而来。核心实现见 `src/main/ets/core/`,对外 API 见 `src/main/ets/WebAccel.ets` 与 `WebAccelView.ets`。

## 对外 API

```ts
import { WebAccel, WebAccelView, WebAccelOptions, RemoteApp } from 'webaccel';
```

| API | 说明 |
|---|---|
| `WebAccel.init(context, options?)` | 开机初始化(UIAbility.onCreate 调一次):内核 + 离线缓存 + 配置一把梭 |
| `WebAccel.attach(uiContext)` | 提供 UIContext(离屏预渲染需要),首个页面 aboutToAppear 调一次 |
| `WebAccel.prewarm(url, swrDoc?)` | 预热某网页(预连接 + 主文档 SWR + 离屏预渲染) |
| `WebAccel.obtain(url)` | 取已渲染节点(`WebAccelView` 内部用;也可自行 `NodeContainer` 挂载) |
| `WebAccel.goBack(url)` | 网页能后退则后退,宿主页 `onBackPress` 转调 |
| `WebAccel.getApps()` / `setApps(apps)` | 读 / 运行时直接喂应用列表 |
| `WebAccel.refreshConfig()` | 手动拉一次后台最新配置 |
| `WebAccel.stats()` / `bundleProgress(origin)` | 缓存统计 / 某站离线包进度(调试) |
| `WebAccelView({ url })` | 开箱即用展示组件:节点挂载 + 白屏占位 + 离线进度条 |

### `WebAccelOptions`

```ts
interface WebAccelOptions {
  configServer?: string;     // admin 后台地址;不填 = 不联网,用 apps 直供
  apps?: RemoteApp[];        // 直供应用列表(不依赖后台时用)
  blockHosts?: string[];     // 过滤黑名单(覆盖默认内置)
  settings?: RemoteSettings; // 缓存上限 / 校验节流(bytecodeCache 字段在元服务被忽略)
  autoRefresh?: boolean;     // 有 configServer 时是否开机异步拉最新(默认 true)
}
```

## 三步接入

**1) 依赖**(接入方 `oh-package.json5`):

```json5
{ "dependencies": { "webaccel": "file:../webaccel" } }
```

**2) 初始化**(`EntryAbility.ets` / `onCreate`):

```ts
import { WebAccel } from 'webaccel';

WebAccel.init(this.context, { configServer: 'https://admin.example.com' });
// 或不依赖后台,直接喂列表:
// WebAccel.init(this.context, { apps: [{ id: 'a', name: '应用A', url: 'https://a.example.com/' }] });
```

**3) 预热 + 展示**:

```ts
// 列表页 aboutToAppear
WebAccel.attach(this.getUIContext());
for (const a of WebAccel.getApps()) { WebAccel.prewarm(a.url, true); }

// 展示页 build()
WebAccelView({ url: this.url })
// 展示页 onBackPress
onBackPress(): boolean { return WebAccel.goBack(this.url); }
```

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
