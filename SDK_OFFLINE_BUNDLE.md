# SDK Offline Bundle Mechanism

更新时间: 2026-07-07

本文说明当前定版的离线包机制。重点:端侧 SDK 不再做运行时静态资源自动缓存,只下载后台离线包清单中的资源。

## 核心边界

harm-youhua 提供两部分能力:

1. `webaccel` HAR SDK: 集成到接入方 App 或元服务中。
2. 后台离线包服务: 下发 `/api/config` 和 `/bundles/<site>/manifest*.json`。

接入方端侧不需要自己判断哪些资源要缓存。后台负责筛选资源并生成离线包;SDK 启动后拉后台配置,对 `bundle:true` 的站点下载离线包。离线包最终写入接入方 App 自己的沙箱 `context.filesDir/webcache`。

这不是把离线包打进 HAP,也不是端侧访问网页后自动抓资源缓存。

## 当前不做的能力

1. 不做端侧运行时静态资源自动缓存。
2. 不做端侧根据体积或耗时自行决定缓存。
3. 不做预渲染。
4. 不做 SWR 主文档缓存。
5. 不做 chunk 预取。
6. 不做后台实时强推更新。

## 多站点下载模型

后台配置里每个站点按 `RemoteApp` 描述:

```text
bundle=true                  # 开启离线包
manifestUrl                  # 原始 manifest
compressedManifestUrl         # 压缩 manifest,新 SDK 优先使用
bundleVersion                 # 原始 manifest 指纹
compressedBundleVersion       # 压缩 manifest 指纹
```

SDK 初始化流程:

1. 拉 `/api/config`。
2. 确认配置来源是服务端最新配置。
3. 遍历后台返回的 `apps`。
4. 对 `bundle:true` 且有 manifest 的站点全部启动离线包下载。
5. 旧沙箱缓存配置只用于兜底展示,不会抢先触发全量下载。
6. 写入接入方应用沙箱。
7. WebView 请求同一个原站 URL 时,SDK 拦截并返回本地资源。

后台有多个 `bundle:true` 站点时,端侧会逐站进入下载队列,不是只下载当前打开页面对应的离线包。这样首次安装后只要应用启动并成功拉到服务端配置,所有已开启离线包的站点都会开始准备。

这个策略的代价是首装会产生集中下载和沙箱占用增长,所以后台必须控制总大小,尤其不要把图片、视频、非关键字体等低收益大资源随意放入离线包。

## 命中流程

```text
WebView 请求原站 URL
-> SDK onInterceptRequest
-> 查沙箱索引
-> 命中 .zz:读取压缩字节,内存解压,返回原文
-> 命中原始文件:直接返回
-> 未命中:放行网络,不写运行时缓存
```

缓存 key 是网页真实 URL,不是后台 `/bundles/...` URL。后台只是下载源。

## 压缩离线包

后台同时保留:

1. `manifest.json`:原始资源清单,兼容旧 SDK。
2. `manifest.zz.json`:压缩资源清单,新 SDK 优先使用。

文本资源如 JS/CSS/HTML 会生成 `.zz` 文件。端侧沙箱保存压缩字节,命中 WebView 前用 zlib 解压,返回原始 JS/CSS/HTML。

不要直接用 `Content-Encoding` 把压缩字节返回给 ArkWeb。实测可能让 ArkWeb 把压缩字节当 JS 解析,触发语法错误。

## 更新机制

后台重建或导入资源后,manifest 内容变化,版本号也变化。

端侧发现新版本的方式只有两种:

1. 重新打开应用,SDK 重新初始化并拉 `/api/config`。
2. 接入方主动调用 `WebAccel.refreshConfig()`。

当前不是后台改完后实时推送到端侧。如果要实时更新,后续需要增加推送、长连接或定时轮询。

## 调试浮窗语义

当前调试浮窗不再显示“缓 N 条”。

显示规则:

```text
包准备中       # 该站 bundle=true,但还没有拿到 manifest 进度
包下载 x/y     # 离线包正在下载
包完成 x/y     # 离线包已经全部落到沙箱
未配置离线包   # bundle 不为 true
```

验证性能时,应等待目标站点显示 `包完成 x/y` 后再进入页面。首次安装后如果还在 `包下载 x/y`,页面资源可能仍走网络。

## 沙箱预算和风险

离线包最终仍要落到接入方应用沙箱。当前按约 200MB 预算理解,SDK 内部仍有容量控制和 LRU 淘汰。

风险:

1. 用户清除应用数据、重装应用、系统清理沙箱,都会导致本地离线包消失。
2. 本地离线包消失后页面会回退走网络,不会直接打不开。
3. 下次 SDK 初始化会重新下载后台离线包。
4. 后台必须控制每个站点离线包大小,避免首装下载过多、耗流量、耗电。

## 资源选择原则

优先进入离线包:

1. 首屏必须依赖的 JS/CSS。
2. 字体文件,尤其中文字体。
3. 体积大且 URL 稳定的静态资源。
4. 二级页必须依赖的路由 chunk。
5. 真机日志中下载慢或影响展示的关键资源。

不要进入离线包:

1. MP4 视频、大体积媒体流。
2. 动态接口响应。
3. 埋点、广告、风控、探针脚本。
4. 带随机参数或会话态的 URL。
5. 对页面启动无关键作用的小资源。

## 新加坡环球影城当前状态

应用:

```text
id: rwsentosa
name: 新加坡环球影城
url: https://www.rwsentosa.com/zh-cn/play/universal-studios-singapore
```

配置:

```text
bundle=true
staticCache.enabled=false
swrDoc=false
prerender=false
prefetchChunks=false
bundleMaxSizeKB=12288
bundleExtraUrls=27
```

离线包:

```text
资源数: 27
原始大小: 11265.9 KB
压缩/端侧落盘: 7116.3 KB
资源类型: JS、CSS、字体
```

已放入离线包的字体包括:

```text
noto-serif-sc-v7-chinese-simplified-300.woff2
noto-serif-sc-v7-chinese-simplified-900.woff2
noto-sans-sc-v11-chinese-simplified-700.woff2
RWSHeader-Regular.ttf
RWSBody-Regular.ttf
RWSBody-Light.ttf
RWSBody-LightItalic.ttf
rws-icons.woff2
AlegreyaSans*
AlegreyaSansSC*
```

页面慢的结论:

1. 后台构建耗时小,只说明服务器到 RWS/CDN 拉资源快。
2. 手机体验慢是端侧下载离线包、解压、执行 JS、字体排版、图片/视频渲染的综合耗时。
3. RWS 页面本身包含较重 JS、中文字体、图片和视频。离线包能减少关键静态资源网络拉取,但不能消除 WebView 渲染和视频/图片带来的 load 时间。

## 接入方需要知道

接入方只需要:

```ts
WebAccel.init(this.context, {
  configServer: 'https://maidun.chujingservice.com'
});
```

如果只传本地 `apps` 且没有 `configServer`,SDK 不会从后台下载离线包。要实现进入前已缓存,必须配置后台地址,并在后台让目标站点有 `bundle:true` 和 manifest。
