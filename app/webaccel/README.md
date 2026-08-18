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

对外 API 没有新增必须接入的接口;这次新增的是可选 `configRefreshSec`,用于让端侧按间隔自动轮询后台 `/api/config`。

## 对外 API

```ts
import { WebAccel, WebAccelLauncher, WebAccelView, WebAccelOptions, RemoteApp } from 'webaccel';
```

| API | 说明 |
|---|---|
| `WebAccel.init(context, options?)` | UIAbility.onCreate 调一次,初始化 Web 内核、读取本地配置、拉后台配置和离线包 |
| `WebAccelLauncher()` | 开箱即用整页组件:地区列表 + 当前地区应用列表 + 网页容器 + 返回 + 调试浮窗 |
| `WebAccelView({ url })` | 自定义壳时使用的网页容器 |
| `WebAccel.goBack(url)` | WebView 能后退则后退 |
| `WebAccel.loadBundle(url)` | 只触发指定网页应用离线包下载,不打开 WebView |
| `WebAccel.loadBundleForApp(app)` | 按 app id 精确触发离线包下载,适合同 URL 多地区配置 |
| `WebAccel.loadTopBundles()` | 主动拉取 `scope=top` 的常驻离线包 |
| `WebAccel.switchRegion(region)` | 切换地区:中断旧地区任务、删除旧地区缓存、拉取新地区离线包 |
| `WebAccel.deleteRegion(region)` | 删除某地区离线包缓存,不影响 top |
| `WebAccel.deleteBundle(id)` | 删除某个网址 id 的离线包缓存 |
| `WebAccel.handleSchemeRequest(request, handler)` | 给外部 WebView/SchemeHandler 使用的离线命中入口 |
| `WebAccel.getConfigJson(idOrUrl)` | 读取随离线包保存的 H5 配置 JSON |
| `WebAccel.updateConfigJson(idOrUrl, configJson)` | 宿主拿到最新 H5 配置后同步给离线兜底 |
| `WebAccel.getApps()` / `setApps(apps)` | 读取或直接注入应用列表 |
| `WebAccel.getAppRegions(app)` | 返回应用的全部地区 ID,兼容旧版单值 `region` |
| `WebAccel.matchesRegion(app, region)` | 判断应用是否属于当前地区;接入方不要自行比较 `app.region` |
| `WebAccel.refreshConfig()` | 手动拉一次后台最新配置,并立即按当前地区重新匹配和下载地区包 |
| `WebAccel.bundleProgress(idOrUrl)` | 查询某个 id / URL 的离线包下载进度 |
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
  configRefreshSec?: number; // 后台应用 JSON 轮询间隔；线上默认 60 秒，SDK 内置默认 300 秒，0 表示关闭
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

## 接入已有 WebSDK 容器

如果宿主已经有自己的 H5 容器、`configJson` 注入和 JSBridge,不要替换成 `WebAccelView`。保留原容器,只把离线命中接进 SchemeHandler:

```ts
import { WebAccel } from 'webaccel';

class OfflineRequestHandler implements IHandleRequestStart {
  getTag(): string {
    return 'WebAccelOffline';
  }

  onHandleRequestStart(request: webview.WebSchemeHandlerRequest,
    handler: webview.WebResourceHandler): boolean {
    return WebAccel.handleSchemeRequest(request, handler);
  }
}

schemeHandler.addHandler(new OfflineRequestHandler());
controller.setWebSchemeHandler('https', schemeHandler);
```

推荐 handler 顺序:

```text
WebAccelOffline -> 业务代理/特殊站点 handler -> 网络监控 observer
```

H5 配置兜底:

```ts
try {
  const configJson = await requestWebConfigFromBusinessApi(appId);
  WebAccel.updateConfigJson(appId, configJson);
  return JSON.parse(configJson);
} catch (_) {
  const cached = WebAccel.getConfigJson(appId);
  if (cached.length > 0) {
    return JSON.parse(cached);
  }
  throw _;
}
```

## 地区缓存模型

后台每个网址必须有稳定 `id`。SDK 按 `id` 保存 bundle state,按原始 URL 命中资源。

```ts
const apps: RemoteApp[] = [
  {
    id: 'top_exchange_rate',
    name: '汇率',
    url: 'https://example.com/rate/',
    scope: 'top',
    bundle: true,
    configJson: '{...}'
  },
  {
    id: 'getyourguide',
    name: 'GetYourGuide',
    url: 'https://www.getyourguide.com/',
    scope: 'region',
    regions: ['100253', '100678', '2036722743924088834'],
    region: '100253', // 后台自动维护的旧 SDK 兼容值,业务代码不要直接判断它
    bundle: true,
    configJson: '{...}'
  }
];
```

规则:

1. `scope: "top"`: SDK 初始化后自动拉取,长期保留。
2. `scope: "region"`: 宿主调用 `WebAccel.switchRegion(regionId)` 后拉取该地区包。
3. `regions` 可配置多个地区 ID;切到其中任一地区都会加载同一个应用 `id` 对应的离线包,服务端和沙箱不会按地区复制多份。
4. `region` 是旧 SDK 兼容字段,后台固定为 `regions[0]`;接入方应调用 `WebAccel.matchesRegion(app, currentRegion)`。
5. 切香港到英国时,SDK 会让香港未完成任务失效,删除香港 `scope=region` 缓存,再拉英国包。
6. `scope: "app"`: 不自动拉,宿主可用 `WebAccel.loadBundleForApp(app)` 或打开页面时触发。
7. `configJson` 可放在 `/api/config` 的 app 字段里;新版 SDK 也兼容 manifest 对象格式 `{ "configJson": "...", "resources": [...] }`。
8. 如果后台开启了 `configJsonSync`,该字段会由 admin 定时从第三方后台同步,端侧仍然只看 `/api/config`,不需要额外新增接入 API。

## 离线包规则

1. 后台配置 `scope: "top"` 且 `bundle:true` 时,SDK 初始化后默认拉取对应离线包。
2. 后台配置 `scope: "region"` 时,SDK 只在 `WebAccel.switchRegion(region)` 后拉取该地区离线包。
3. SDK 不会在配置到达时批量下载所有地区离线包。
4. 本地旧配置只作为兜底展示,不会触发全量离线包下载,避免抢先拉旧版本。
5. 资源下载源是后台 `/bundles/<site>/...`,但本地命中 key 是网页原始 URL。
6. 文本资源可用 `.zz` 压缩落盘;命中时端侧内存解压后返回原文给 WebView。
7. 未进入离线包的资源直接走网络,不会被端侧运行时自动缓存。
8. 后台更新应用 JSON 后,端侧启动会立即拉一次,前台会按 `configRefreshSec` 周期自动拉 `/api/config`;当前线上三个环境均配置为 60 秒，也可调用 `WebAccel.refreshConfig()` 立即刷新。
9. 后台更新自建网站的 `configJson` 后,端侧拉到新的 `/api/config` 会直接更新本地兜底 JSON,不要求离线包版本变化。
10. 如果该站点的 `configJson` 由第三方后台自动同步,那么后台定时任务只是把最新 JSON 写进 `/api/config`;SDK 侧的使用方式不变。
11. 后台更新静态资源离线包后,端侧拉到新 `bundleVersion` 会重新下载清单和新增/变更资源;刷新成功后 SDK 会自动检查 TOP、当前地区和当前会话已打开的网站。

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
