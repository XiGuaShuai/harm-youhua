# webaccel —— 后台离线包 SDK(HAR)

`webaccel` 是鸿蒙 ArkWeb 网页应用 SDK。当前版本只保留一条主链路:

```text
SDK 初始化 -> 拉后台 /api/config -> 下载 bundle:true 站点离线包 -> 写入接入方应用沙箱 -> WebView 请求命中本地离线包
```

当前不做:

1. 端侧运行时静态资源自动缓存。
2. 用户访问后端侧自行判断并写缓存。
3. 预渲染。
4. SWR 主文档缓存。
5. chunk 预取。

## 对外 API

```ts
import { WebAccel, WebAccelLauncher, WebAccelView, WebAccelOptions, RemoteApp } from 'webaccel';
```

| API | 说明 |
|---|---|
| `WebAccel.init(context, options?)` | UIAbility.onCreate 调一次,初始化 Web 内核、读取本地配置、拉后台配置和离线包 |
| `WebAccelLauncher()` | 开箱即用整页组件:后台应用列表 + 网页容器 + 返回 + 调试浮窗 |
| `WebAccelView({ url })` | 自定义壳时使用的网页容器 |
| `WebAccel.goBack(url)` | WebView 能后退则后退 |
| `WebAccel.getApps()` / `setApps(apps)` | 读取或直接注入应用列表 |
| `WebAccel.refreshConfig()` | 手动拉一次后台最新配置。后台离线包更新后,可用它主动拉新版本 |
| `WebAccel.bundleProgress(origin)` | 查询某站离线包下载进度 |
| `WebAccel.stats()` | 调试统计 |
| `WebAccel.setDebug(on)` | 调试浮窗开关。显示 `包准备中`、`包下载 x/y`、`包完成 x/y` |

## WebAccelOptions

```ts
interface WebAccelOptions {
  configServer?: string;     // 后台地址,例如 https://maidun.chujingservice.com
  apps?: RemoteApp[];        // 兜底应用列表;后台拉到后覆盖
  blockHosts?: string[];     // 可选黑名单
  settings?: RemoteSettings; // 沙箱容量、离线包并发等
  autoRefresh?: boolean;     // 是否启动后自动拉后台配置,默认 true
}
```

## 推荐接入

`EntryAbility.ets`:

```ts
import { WebAccel } from 'webaccel';

WebAccel.init(this.context, {
  configServer: 'https://maidun.chujingservice.com'
});

// 调试阶段打开,上线关闭
WebAccel.setDebug(true);
```

入口页:

```ts
import { WebAccelLauncher } from 'webaccel';

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
```

## 自定义壳

```ts
import { WebAccel, WebAccelView } from 'webaccel';

const apps = WebAccel.getApps();

WebAccelView({ url });

onBackPress(): boolean {
  return WebAccel.goBack(url);
}
```

也可用 `@StorageLink('apps') apps: RemoteApp[]` 监听后台应用列表更新。

## 离线包规则

1. 后台配置 `bundle:true` 且已有 manifest 时,SDK 会下载该站离线包。
2. SDK 拉到服务端 `/api/config` 后,会把所有 `bundle:true` 站点加入离线包下载队列,不是只下载当前打开页面。
3. 本地旧配置只作为兜底展示,不会触发全量离线包下载,避免抢先拉旧版本。
4. 资源下载源是后台 `/bundles/<site>/...`,但本地命中 key 是网页原始 URL。
5. 文本资源可用 `.zz` 压缩落盘;命中时端侧内存解压后返回原文给 WebView。
6. 未进入离线包的资源直接走网络,不会被端侧运行时自动缓存。
7. 后台更新离线包后,端侧需要重新打开应用或调用 `WebAccel.refreshConfig()` 才会拉到新版本。

## 元服务注意事项

1. 不要把离线包打进 rawfile,离线包走后台下载到沙箱,不计入 HAP 包体。
2. 接入方 `module.json5` 必须声明 `ohos.permission.INTERNET`。
3. 元服务包体限制仍要遵守:单包不超过 2MB,总计不超过 10MB。
4. 沙箱离线包可能被系统清理、用户清除数据、重装应用清空;下次 SDK 初始化会重新下载。

## 构建 HAR

```powershell
cd D:\Work\KCP\harm-youhua\app
$env:DEVECO_SDK_HOME='D:\Huawei\DevEco Studio\sdk'
& "D:\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHar -p module=webaccel@default
```

产物:

```text
app/webaccel/build/default/outputs/default/webaccel.har
```
