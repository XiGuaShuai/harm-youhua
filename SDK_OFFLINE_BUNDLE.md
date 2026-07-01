# SDK Offline Bundle Mechanism

更新时间: 2026-07-01

本文说明 harm-youhua 作为 SDK 方案时,离线包到底由谁提供、何时下载、存到哪里、怎么控制体积。

## 核心边界

harm-youhua 提供两部分能力:

- `webaccel` HAR SDK: 集成到接入方 App 或元服务中。
- 后台离线包服务: 下发 `/api/config` 和 `/bundles/<site>/manifest*.json`。

接入方端侧不需要自己判断哪些资源要缓存。SDK 启动后会拉后台配置,对配置中的站点执行预热和离线包下载。离线包最终写入的是接入方 App 自己的沙箱,也就是 SDK 运行时拿到的 `context.filesDir/webcache`,不是写入我们 demo App,也不是打进 HAP 包体。

## 多站点预下载模型

后台配置里可以有很多网址。每个站点按 `RemoteApp` 描述:

- `bundle: true`: 该站点有离线包,SDK 会下载 manifest 并缓存资源。
- `manifestUrl`: 旧端使用的原始资源清单。
- `compressedManifestUrl`: 新端优先使用的压缩资源清单。
- `bundleVersion` / `compressedBundleVersion`: 用于端侧判断是否需要更新。

SDK 在 `WebPreRender.prewarmConfiguredApps()` 中遍历所有 `apps`。只要站点开启 `bundle: true`,就会调用 `loadBundleFor(app.url)`。因此接入方 App 一启动,会对所有配置站点逐个拉离线包并写入沙箱。用户之后点击任意站点时,关键耗时资源已经在本地,页面才可能做到秒开。

这意味着后台不是只看单个站点大小,而要看所有启用站点的总沙箱预算。每个站点的离线包都要可单独配置、可单独勾选资源、可看到每个资源文件名和大小。

## 端侧存储和命中流程

1. SDK 拉 `/api/config`。
2. SDK 对每个 `bundle: true` 站点拉 manifest。
3. SDK 按 manifest 下载资源文件。
4. 资源写入接入方沙箱 `filesDir/webcache`。
5. WebView 请求同一个 URL 时,SDK 拦截请求。
6. 本地缓存命中则直接返回本地内容;未命中则放行网络,并按策略决定是否回填缓存。

离线包资源的缓存 key 是原站 URL,不是后台 `/bundles/...` URL。后台只是提供资源下载源,端侧命中时仍按网页真实请求的 URL 匹配。

## 压缩离线包

当前新 SDK 支持 `manifest.zz.json`:

- 后台保留 `manifest.json`,兼容旧 SDK。
- 后台额外生成 `manifest.zz.json`,对可压缩文本资源生成 `.zz` 文件。
- 端侧沙箱保存 `.zz` 压缩字节,统计大小按压缩后体积计算。
- 命中 WebView 请求前,SDK 用 zlib 把压缩字节解到内存。
- 返回给 WebView 的仍然是原始 JS/CSS/HTML 内容,不会带 `Content-Encoding`,避免 ArkWeb 把压缩字节当 JS 解析。

不能直接把压缩 JS 通过 `Content-Encoding` 返回给 ArkWeb。实测这种方式会触发 JS 语法错误,例如 `Invalid or unexpected token`。所以当前实现选择“沙箱压缩存储 + 命中前端侧解压 + 原文返回”。

## K11 当前结果

线上 K11 当前离线包:

- 原始 manifest: `6365.1 KB`
- 压缩后端侧落盘: `5794.4 KB`
- 节省: `570.7 KB`
- 资源数: `29`
- 压缩资源: `hk.k11.com_files_art_js_bundle.min.js.zz`
- JS 原始大小: `793.8 KB`
- JS zlib 后大小: `223.2 KB`

K11 图片主要是 JPG/PNG/WebP,本身已压缩,继续压缩收益很低,所以仍按原始图片文件缓存。真正有效的压缩对象主要是 JS/CSS/HTML/JSON/SVG 等文本类资源。

## 2026-07-01 线上站点状态

当前线上后台启用三项测试配置:

- K11 香港: `bundle:true`,原始 `6365.1 KB`,压缩落盘 `5794.4 KB`。
- 印尼出境卡: `bundle:true`,按 `>=64 KB` 或 `>=3000 ms` 保留关键资源,原始 `1690.2 KB`,压缩落盘 `607.7 KB`,资源数 `13`。
- Booking.com: `bundle:false`,服务端请求首页返回 AWS WAF challenge,拿不到可构建离线包的 HTML;当前使用运行时缓存 `bstatic.com` / `bstatic.cn` 大资源 + Booking 遥测黑名单 + preconnect。

当前线上测试目标是验证资源获取速度,所以三个站点均关闭 `prerender` / `swrDoc` / `codeCache` / `prefetchChunks`,全局也关闭 `bytecodeCache`。页面渲染仍完全交给 WebView 内核,SDK 只负责提前把关键静态资源放进沙箱或运行时缓存。

Booking 不应该伪造空离线包。若后续要做 Booking 离线包,必须先用真机 WebView 采集实际 `bstatic` 稳定静态资源,再把可直接下载且 URL 稳定的资源配置进 `bundleExtraUrls`,并验证端侧命中。

## 资源选择原则

离线包不是把访问过的所有东西都塞进去。每个站点应该优先缓存:

- 页面启动必须依赖的 JS/CSS。
- 加载耗时超过阈值的静态资源,例如 K11 当前按 `>=3000ms`。
- 体积大且稳定、URL 带版本号或内容 hash 的静态资源。
- 首页、店铺页、美食页这类关键路径反复出现的固定背景图或固定运营图。

不应该缓存:

- 统计、广告、风控、探针脚本,例如 GA/GTM、abclite、fingerprint。
- URL 不稳定或带随机参数的资源。
- 动态接口响应。
- 对页面启动无关键作用的小资源。
- 已很快加载且体积虽大但不在策略内的资源,避免沙箱被低价值资源吃掉。

## 沙箱预算

接入方沙箱预算按全站点总量计算。即:

```text
总沙箱占用 = K11 离线包 + 印尼入境卡离线包 + Booking 可缓存资源 + 运行时回填缓存 + 索引文件
```

当前 SDK 有全局 `diskCapMB` 和 LRU 淘汰机制。超过上限时会按最近访问时间淘汰旧资源。但产品上仍应在后台控制每站离线包体积,否则用户第一次启动时会下载太多资源,影响流量、耗电和沙箱占用。

后台离线包面板需要持续保留这些信息:

- 每个网站是否启用离线包。
- 每个网站离线包总大小。
- 压缩后端侧沙箱落盘大小。
- 原始大小。
- 每个资源的文件名、原站 URL、类型、下载耗时、原始大小、端侧存储大小。
- 每个资源是否加入离线包的开关。

## 手动导入静态资源

自动发现只适合稳定、可判断的首屏资源。若真机测试时发现某个静态资源耗时长或体积大,可以在后台「离线包资源面板」选择站点后点击「导入资源」,每行粘贴一个完整 URL。

导入会立即执行:

- 下载指定资源到该站离线包目录。
- 把成功下载的 URL 加入该站 `bundleExtraUrls`。
- 自动开启该站 `bundle:true`。
- 重新生成 `manifest.json` 和压缩 `manifest.zz.json`。
- 在资源明细里显示文件名、原始大小、端侧存储大小、下载耗时和状态。

手动导入会信任管理员判断,不再强制要求文件名带 hash。导入前仍应确认资源是静态的、URL 稳定的、不是动态接口或会话相关内容。

## 对接方需要知道的行为

接入方只需要集成 SDK 并调用:

```ts
WebAccel.init(this.context)
```

后台可达时,SDK 会自动拉配置和离线包。接入方不需要手动下载每个站点的资源。若后台配置中有多个 `bundle: true` 站点,端侧会逐站预下载,所以后台配置必须谨慎控制总量。

如果接入方只传本地 `apps` 且没有 `configServer`,则不会从后台下载离线包,只能依赖运行时缓存。要实现“进入前已缓存,页面秒开”,必须配置后台地址并让站点有离线包 manifest。
