# 问题汇总 / 调试记录

本文件汇总联调中遇到的问题、根因与修复,供日后排查参考。
部署 / 运维(服务器、nginx、HTTPS、git push 自动部署)见 [DEPLOY.md](./DEPLOY.md)。

---

## 端侧 SDK / 调试浮窗

### 1. 浮窗显示「配置: 兜底(未连后台)」,但其实已连上
- **现象**:App 已成功拉到 `/api/config`(服务器 nginx 日志可见 `libcurl-agent` GET `/api/config` 200),但浮窗一直橙色「未连后台」,点一下 / 缩小才翻绿。
- **根因**:ArkUI 局部刷新——配置状态行读的是外部 `remoteConfig.getSource()`,不依赖任何 `@State`,每秒定时刷新带不动它;只有交互重建该节点时才重新求值。
- **修复**:`RemoteConfig` 把配置来源 / 版本写进 `AppStorage`,浮窗改用 `@StorageLink('configSource')` 订阅 → 拉到配置即自动翻绿。
- **改动**:`RemoteConfig.ets`、`WebAccelDebugBadge.ets`(commit `648a5e5`)。

### 2. 浮窗「包 X/Y」进度数字不实时
- **现象**:各应用缓存进度只有点击浮窗后才变。
- **根因**:进度文本在 `ForEach` 里调外部 `webCache`,`ForEach` 仅在数据源 `apps` 变化时重建,不随进度重绘。
- **修复**:定时器每秒把各应用进度算成 `@State` 数组快照,行内读快照 → 每秒实时刷新。
- **改动**:`WebAccelDebugBadge.ets`(commit `61c52a5`)。

### 3. 新加坡环球影城页「一张大图」一直裂
- **现象**:USS 购票页顶部大图加载不出来(其它图正常)。
- **根因**:大图文件名含尺寸串 `...masthead_en_2160x1140-1.jpg`,`2160x1140`(9 位、数字+`x`)被 `isHashedAsset` 误判成「内容 hash」→ SDK 当**不可变资源永久缓存**;慢代理下载被截断 → 缓存了坏副本且**永不回源**。
- **修复**:`isHashedAsset` 排除 `数字x数字` 尺寸串(SDK 与 admin `cache-builder` 两处)。
- **改动**:`WebCacheManager.ets`、`cache-builder.js`(commit `38f4873`)。需 **App 重新构建 + 清一次缓存**。

---

## 离线包 / cache-builder(admin)

### 4. 深层子页入口打包几乎全失败
- **现象**:rwsentosa 入口从首页改成 USS 子页后,离线包 `discovered=5 / failed=4 / 0KB`。
- **根因**:cache-builder 假设入口是站点根,用 `base`(= 子页 URL)拼资源下载地址 → 404;主文档还固定记成 `origin + '/'`,设备按子页 URL 命不中。
- **修复**:支持子页入口——同源资源一律按 `origin` 拼、主文档按**入口页真实路径**回种;对根页 App(beacukai)等价不受影响。
- **改动**:`cache-builder.js`(commit `8c7c963`)。

### 5. 动态 SPA 页:离线包(bundle)喂「服务器快照」导致内容不全
- **现象**:USS 购票页(CRA 动态 SPA)曾出现部分内容出不来;浏览器实时加载正常。(当时还叠加了 #3 那张大图的 bug,真凶主要是 #3。)
- **根因**:**离线包的 `home.html` 是 cache-builder 在服务器抓的快照**,与设备实际加载的(区域 / 会话 / 反爬变体)不一致 → 喂给设备就缺内容。
- **处理 / 正确配置**:
  - **`bundle:false`** —— 动态页不喂服务器快照;
  - **`swrDoc:true`** —— 它缓的是**设备自己加载过的那份文档**(同环境、同会话),重开秒出、后台校验,对动态页**安全**且能秒开;
  - **`prerender:true`** —— 离屏预渲染,首开即显。
- **经验**:动态 SPA → `bundle:false + swrDoc:true + prerender:true`;静态页(如 beacukai)→ 可用完整离线包。

---

## 站点接入经验

### 6. Booking.com
- **反爬**:服务器 curl 只得 ~4KB 空壳;静态资源在跨域 CDN(`bstatic` / `booking.cn`)→ **不能用离线包**(cache-builder 只抓同源)。
- **搜索为何慢**(实测瀑布):① Booking 后端出 **233KB SSR HTML(~2s)** + `dml/graphql` 搜索 API;② 一页 **~46 个 XHR**,一大半是遥测;③ **香港代理延迟**。
- **已拦遥测 / 追踪**:`otel-gw` · `sink.gw` · `gtp-mktg` · `booking.com/c360`(第一方点击流)· `google.com/ccm` · `s.yimg.jp`(广告 bing/adsrvr/GA/GTM 本就在黑名单)。
- **天花板**:后端 + 代理,框架碰不了;**换更快 / 更近的代理出口收益最大**。
- 中国大陆访问会先撞 PIPL 同意墙(`pipl_consent.zh-cn.html`)、走 `booking.cn` CDN,与香港代理→国际版不同,调试需注意区域差异。

### 7. 新加坡环球影城(rwsentosa)
- **名称** = 「新加坡环球影城」;**入口** = USS 购票页 `https://www.rwsentosa.com/en/play/universal-studios-singapore/tickets`。
- 它是 CRA 站,静态资源在 `/dist/rwsentosarevamp/static/...`(带 hash,可缓存)。
- **当前配置**:`bundle:false, swrDoc:true, prerender:true`(动态页:不喂服务器快照,但缓设备自己的主文档 + 离屏预渲染 → 秒开;运行时再缓存带 hash 静态资源)。

---

## 通用经验
- **加速框架能动的**:静态资源缓存(运行时 / 离线包)、主文档 SWR、预渲染、黑名单拦遥测。
- **框架动不了的**:站点后端响应、动态 API、代理 / 网络延迟。
- **秒开靠什么**:`prerender`(离屏预渲染,首开即显)+ `swrDoc`(缓主文档,重开秒出)。**运行时缓存(浮窗「缓N条」)只加速静态资源、不管首屏文档,单靠它不能秒开。**
- **bundle vs swrDoc**:bundle 的 home.html 是「服务器抓的快照」(适合静态页);动态页用 swrDoc(缓设备自己加载的文档)更安全。
- **调试浮窗**:`WebAccel.setDebug(true)` 开启;看「配置来源 / 命中 R(内置)D(沙箱) / 透传 / 拦」判断问题在缓存还是网络还是黑名单。
- 区域差异:服务器(海外)、调试浏览器(大陆)、设备(香港代理)看到的站点可能不同,排查时注意。
