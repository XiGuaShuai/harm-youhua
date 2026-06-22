# CLAUDE.md

本文件给 Claude Code(以及任何接手的人)提供这个仓库的导航。先读这里,再下钻到子目录的 README。

## 这是什么

`youhua-mono` —— 「网页应用集合」**鸿蒙加速方案**的单仓库(monorepo)。

目标:把一组网页应用(如新加坡环球影城购票、印尼海关、Booking 等)包进一个**鸿蒙元服务(Atomic Service,免安装)**,通过多层加速(离线缓存 / 主文档 SWR / 离屏预渲染 / chunk 预取 / 黑名单拦遥测)让用户**点开即秒显**;并配一个后台,让"应用列表 / 黑名单 / 离线包"都能**远程下发、改东西不用重新发版**。

近期方向(见 git log):端侧加速 → Docker 一键部署 → 离线包版本化增量更新 → **众包上报 / 共识自动建包**(设备匿名采样上报资源,服务端用同款 djb2 指纹复算校验防投毒,投票数达阈值即自动建离线包)。

## 仓库结构

```
youhua-mono/
├── app/                鸿蒙元服务工程(端侧)—— DevEco Studio / hvigor 构建
│   ├── webaccel/       加速能力封装成的 HAR SDK(可被别的工程复用)
│   └── entry/          元服务本体 HAP(installationFree,几行代码消费 webaccel)
├── admin/              配套后台
│   ├── server/         Node + Express:配置 API + 离线包托管 + 众包上报
│   └── web/            Vue3 + Vite + Element Plus + Pinia 管理界面
├── deploy/             部署脚本 / nginx 配置(bootstrap-server.sh、nginx-maidun.conf)
├── docker-compose.yml  后台编排(admin 容器 + mysql 容器,命名卷持久化)
├── DEPLOY.md           部署 / 运维(服务器、nginx、HTTPS、git push 自动部署)
└── TROUBLESHOOTING.md  联调问题汇总 + 根因 + 修复(强烈建议接手前先读)
```

**端 ↔ 后台关系**:元服务开机从后台拉 `/api/config`(应用 / 黑名单 / 设置),打开网页时按需下载离线包进沙箱(自愈式缓存);后台改配置或打包,端侧下次启动即生效,**无需重新发版**。

> 子文档:SDK API 见 `app/webaccel/README.md`;工程维护 / 发版见 `app/UPDATE.md`;后台接入见 `admin/README.md`;部署见 `DEPLOY.md`;踩坑见 `TROUBLESHOOTING.md`。

---

## app/ —— 鸿蒙元服务工程

两层模块:`webaccel`(HAR,加速能力 SDK)+ `entry`(HAP,元服务本体,只几行代码消费 SDK)。

### 关键文件

| 文件(相对 app/) | 职责 |
|---|---|
| `AppScope/app.json5` | `bundleType: "atomicService"` —— ★ 声明整体为元服务(免安装) |
| `entry/src/main/module.json5` | `installationFree: true` + `INTERNET` 权限 —— ★ 本 HAP 免安装声明 |
| `entry/src/main/ets/entryability/EntryAbility.ets` | `WebAccel.init(...)` 一行初始化 + `setDebug(true)` + 卡片直达 |
| `entry/src/main/ets/pages/Index.ets` | 入口页:`WebAccelLauncher()` 一行,全程序就这一个页面 |
| `webaccel/src/main/ets/WebAccel.ets` | ★ 门面 API(init/attach/prewarm/obtain/goBack/getApps/refreshConfig/stats/setDebug) |
| `webaccel/src/main/ets/WebAccelLauncher.ets` | 开箱即用整页组件(列表 + Navigation + 网页 + 调试浮窗) |
| `webaccel/src/main/ets/WebAccelView.ets` | 网页展示组件(占位 + 离线进度条) |
| `webaccel/src/main/ets/WebAccelDebugBadge.ets` | 可拖动调试浮窗(缓存命中 / 后台缓存进度 / 配置来源) |
| `webaccel/src/main/ets/core/RemoteConfig.ets` | 远程配置单例:拉 `/api/config`、写 `AppStorage('apps')`、缓存到沙箱 |
| `webaccel/src/main/ets/core/WebCacheManager.ets` | `onInterceptRequest` 拦截 + LRU 缓存 + 主文档 SWR + 黑名单短路 + 离线包增量 + 众包上报 |
| `webaccel/src/main/ets/core/WebPreRender.ets` | 离屏预渲染池(`BuilderNode` 离屏建 Web,点开秒显) |
| `webaccel/src/main/ets/core/WebShared.ets` | Web 统一配置 + ViewModel + buildWeb @Builder |
| `webaccel/Index.ets` | SDK 对外导出入口 |
| `webaccel/build-profile.json5` | ★ `CONFIG_SERVER` 内置后台地址(debug/release 各一份) |

### SDK 核心 API(`WebAccel` 静态门面)

`init(ctx, options?)`(开机调一次)· `attach(uiContext)` · `prewarm(url, swrDoc?)` · `obtain(url)` · `goBack(url)` · `getApps()`/`setApps(apps)` · `refreshConfig()` · `stats()`/`bundleProgress(origin)` · `setDebug(on)`/`isDebug()`。

组件:`WebAccelLauncher(title?, accentColor?)`、`WebAccelView({ url })`、`WebAccelDebugBadge`。

每个 app 的关键开关(`RemoteApp`):`swrDoc`(主文档陈旧即用,默认 true)、`prerender`(离屏预渲染)、`bundle`(启用离线包)、`routes`(chunk 预取)、`manifestUrl`/`bundleVersion`(后台下发)。

### 构建

```bash
cd app
# 单独产出 SDK(HAR;entry 构建会自动并入,无需手动先跑)
hvigorw assembleHar -p module=webaccel@default
# 构建元服务 HAP
hvigorw --mode module -p module=entry@default -p product=default assembleHap
```

### 元服务硬约束(改 app/ 前务必记住)

- **单包 ≤ 2MB、总计 ≤ 10MB** —— **不打 rawfile 内置离线包**,所有离线资源运行时下载进沙箱(`filesDir`),不计包体。
- **签名**:元服务需在 DevEco `File > Project Structure > Signing Configs` 配自动签名(需已开通元服务的华为账号);**普通 App 证书不能用**。
- **字节码注入已禁用**(元服务不支持 `injectOfflineResources` / `OfflineResourceType`)。

---

## admin/ —— 后台(Node + Express + Vue3)

后端 8787(同源托管前端 dist),Vue 管理界面开发时 5174 代理到 8787。

### server/(Node + Express)

| 文件(相对 admin/) | 职责 |
|---|---|
| `server/index.js` | Express 核心入口:配置读写、账号 / 会话鉴权、所有 API 路由、缓存触发 |
| `server/cache-builder.js` | 离线包构建:抓首页 + 路由 chunk、按内容 hash 命名、生成 manifest(check/update/build/manifest 四模式) |
| `server/consensus-builder.js` | 众包共识建包:从 votes 表取 ≥K 票的稳定资源,服务端用 djb2 复算 hash 校验防投毒,产物与 cache-builder 同构 |
| `server/db.js` | MySQL 连接池 + 幂等建表(`votes` 表,一人一票) |
| `server/data/config.json` | 配置持久化(apps + blockHosts + settings + version),纯文件改完即生效 |
| `server/data/users.json` | 登录账号(密码 scrypt 加盐哈希) |
| `server/data/sessions.json` | 会话 token(7 天,重启不掉线) |
| `server/bundles/<appId>/` | 离线包托管(资源 + manifest.json) |
| `admin/Dockerfile` | 多阶段构建(web build → server 运行,同源托管 dist) |

### API 接口

**公开**:`GET /api/config`(端侧开机拉)· `GET /bundles/<id>/manifest.json` + `/bundles/<id>/*` · `POST /api/login` · `POST /api/report`(设备众包上报,限频 + 校验)。

**后台管理**(需 `X-Admin-Token` 头):`/api/admin/config`、`PUT /api/admin/{apps,blockhosts,settings}`、`POST /api/admin/password`、`/api/admin/db`、`GET /api/admin/report/:id`(共识统计)、`POST /api/admin/report/:id/build`(众包建包)、`POST /api/admin/bundles/:id/{check,update,build,manifest}`(离线包操作)。

### web/(Vue3 + Vite + Element Plus + Pinia)

视图:`Dashboard`(概览)· `Apps`(应用增删改 + 各加速开关)· `Blocklist`(黑名单)· `Bundles`(离线包检查 / 更新 / 构建 / 共识建包)· `Settings`(全局设置)。
状态:`stores/auth.js`(登录态)· `stores/config.js`(配置)。`api/index.js` 自动带 `X-Admin-Token`、401 跳登录。

### 本地起后台

```bash
cd admin/server && npm install && npm start      # 后端 8787(npm run dev = node --watch 自动重启)
cd admin/web && npm install && npm run dev        # 管理界面 5174(代理 /api、/bundles → 8787)
```

依赖:server = `express` / `cors` / `mysql2`;web = `vue3` / `vue-router` / `pinia` / `element-plus` / `axios` / `vite`。

---

## 部署(摘要,详见 DEPLOY.md)

- 后台用 **Docker + git push 自动部署**,跑在服务器 `47.236.73.89`,由宿主机 nginx 反代,对外域名 **`maidun.chujingservice.com`**。
- 容器只绑 `127.0.0.1:8787`,不暴露公网;数据用命名卷(`admin-data` / `admin-bundles` / `admin-mysql`)持久化,换镜像不丢。
- 日常更新:本地 `git add -A && git commit && git push server main` → 服务器自动 `docker compose up -d --build`。
- 端侧后台地址在 `app/webaccel/build-profile.json5` 的 `CONFIG_SERVER`;release 包要求 HTTPS。

---

## 给 Claude 的工作提示

- **改加速行为前先读 `TROUBLESHOOTING.md`** —— 里面记了多个反直觉的坑(如 `2160x1140` 尺寸串被误判成内容 hash 导致坏副本永不回源;动态 SPA 喂服务器快照导致内容不全 → 正确配置是 `bundle:false + swrDoc:true + prerender:true`)。
- **黑名单 / 应用列表是后台下发的**,要给某站加屏蔽域请改 admin 配置(`web` 界面或 `config.json`),**不要往 SDK 硬编码里加**。
- **缓存逻辑改动通常涉及两处**:SDK 的 `WebCacheManager.ets` 和后台的 `cache-builder.js`(如 `isHashedAsset` 判定要两边一致);众包指纹算法(djb2)要求**端侧上报与服务端复算一致**。
- `.gitignore` 已排除运行时数据(`admin/server/data/`、`bundles/`)和 `.env`(含密码),不要提交这些。
- 本仓库**当前 git 远程走代理 `127.0.0.1:7896`,但该代理坏掉**(502 / TLS 失败);需要 git 联网时用 `git -c http.proxy= -c https.proxy= <命令>` 绕过(直连 GitHub 是通的)。

---

## 当前工作进展(2026-06-17,下次会话从这里接上)

**任务**:把 3 个应用(K11/Booking/印尼入境卡)优化到"秒点秒开",离线包做小,HAR+后台简化(后续要上架十几个,目标"纯后台配置上架")。截止周一(2026-06-22)前要看效果。已获授权:**实测+改代码+重编验证,只在本地改、不提交 git**。性能验收标准见 `性能测试报告.xlsx`(B标牵引,要超出)。

### 已搭好的真机联调环境(本机 admin 用户)
- **真机**:HUAWEI HBP-AL00(HarmonyOS 6.0,API22),hdc 序列号 `2NX0123C29000677`。**必须用 DevEco 自带 hdc**:`D:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe`(3.2.0b),不能用 `D:\hdc`(3.1.0b,版本不匹配)。
- **本地后端** 8787 + **管理界面** 5174(admin/admin123)。MySQL 没起不影响配置/离线包(优雅降级)。
- **真机连本地后端**:`CONFIG_SERVER` 已改指 `http://192.168.20.197:8787`(本机以太网 IP,真机已 ping 通),并加了网络安全配置放行明文 HTTP。

### 命令行编译/装真机(关键,见记忆 harm-youhua-build-on-this-machine)
```
$deveco="D:\Huawei\DevEco Studio"; $env:DEVECO_SDK_HOME="$deveco\sdk"
$env:Path="$deveco\tools\node;$deveco\tools\hvigor\bin;$deveco\tools\ohpm\bin;$env:Path"
cd D:\Work\KCP\harm-youhua\app
hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap --no-daemon
```
产物 `app/entry/build/default/outputs/default/entry-default-signed.hap`(约 410KB)。装:`hdc file send` 到 data/local/tmp + `hdc shell bm install -p`;启动 `aa start -b com.atomicservice.6917596829912522753 -a EntryAbility`。

### 为"在本机能编译"做的环境适配改动(4 处,未提交 git,正式发版要还原)
1. `app/hvigor/hvigor-config.json5` + `app/oh-package.json5`:modelVersion 6.0.1→6.0.0。
2. `app/build-profile.json5`:签名换成本机现成证书(借 `D:\Work\Pin2eat\pin2atm` 的 admin 名下 debug 签名)。
3. `app/AppScope/app.json5`:bundleName 改成证书授权的 `com.atomicservice.6917596829912522753`(原值 `...6917607803528486696`)。

### 优化前真机基线(3轮稳定值)
冷启动 e2e ≈490ms;印尼入境卡加载≈730ms(有离线包);K11≈1690ms;Booking≈2714ms(瓶颈在源站+代理)。三站当前同时 prebuild 互抢资源。

### 性能报告关键发现(`性能测试报告.xlsx`)
报告已自带问题归类。**最该拿分的是 ③ "loading 遮罩滞后"**(页面已加载完但 loading 还挂几秒,框架可解):K11停1.7s、新加坡环球影城结算页虚耗7s、booking搜索/详情停几秒。其次 ② JS大/首屏重(缓存/离线包/预取可解)。① 跨境回源/④ 源站慢是天花板,框架碰不了,报告要如实标注。

### 已完成的优化(端侧 HAR webaccel + 后端,均已真机验证,用户确认"确实快")
**端侧加速代码(在 webaccel HAR 里,改完编译 entry HAP 装真机):**
- `webaccel/.../core/WebShared.ets`:① chunk 预取从 onPageEnd+3s 提前到 FCP 即取;② **秒开**:onProgressChange 进度≥85% 且未FCP 时主动消占位(治动态SPA占位傻等到 onPageEnd)。注:曾加"注入脚本隐藏网站loading元素",因 `[class*=loading]`/`[splash]` 模糊匹配会误伤正常容器(后证实那次"样式变了"其实是网站本身),**已移除,勿再加改页面DOM的方案**。
- `webaccel/.../core/WebPreRender.ets`:① 预渲染加优先级 MAX_EAGER_PRERENDER=2,只热预前2个,其余轻量预热+延迟分批补,避免多站同时建Web抢首屏。② **通用路由预取**(治"点二级页慢"):原 prefetchSiteChunks 只认 Next.js/webpack(K11非Next站→空转,二级页资源没预取),新增 WebCacheManager.prefetchRoutes(origin,routes):对配了 routes 的站,冷启动延迟2.5s 对每个路由页 httpGetText 抓主文档→入缓存+SWR→**解析其引用的 `<script>/<link>/<img>` 同源可缓存资源(shouldCache 判断)→ download 预下载**(治"二级页资源多很卡")。已真机验证 `prefetchRoutePage .../forms/bc22 queued 1 res`。**用户配合方式**:用户测出哪些页面卡→给URL→加进该应用 config.json 的 routes→重下发即预取该页主文档+同源资源。**边界**:只缓同源静态资源;跨域资源/动态接口数据(餐厅列表/酒店搜索)仍实时拉,框架管不了——抓日志时帮用户分清"缓资源有用 vs 数据慢缓不了"。
- **⚠️ 重大教训(2026-06-18)**:路由预取最初版本会**抓二级页主文档并缓存(enableDocCache+fetchAndStore text/html)**,结果印尼入境卡(Next.js动态站)点 keberangkatan 下表单页**直接 error**——因为动态页主文档带会话状态,缓了旧版就出错。这正是 TROUBLESHOOTING.md 早警告的"动态SPA不能喂缓存主文档"。**已修正:prefetchRoutePage 只用 httpGetText 拿 HTML 文本来【解析引用的静态资源并预下载】,绝不缓主文档本身、不 enableDocCache**。用户原话定调:"页面是动态的就不要缓存,缓存的是资源、提早下载的那种"。**铁律:预取/缓存只针对静态资源(JS/CSS/图片),永远不缓动态页的 HTML 主文档**(主文档的 SWR 只对入口首页由 prewarm 单独管)。
- `entry/.../EntryAbility.ets`:FALLBACK_APPS=K11/Booking/印尼入境卡三站。
**离线包覆盖增强:版本号 query 资源可缓存(端云一致改,2026-06-17)**
- 背景:K11(hk.k11.com)核心 JS/CSS 其实**同源**(/files/art/,793KB JS+793KB CSS含内嵌字体),但命名是 `bundle.min.js?2025121805`(query版本号,非内容hash),被原 isHashedAsset 判为不可缓存而漏掉。实测推翻了"K11资源全跨域"的旧判断(只有图片跨域)。
- 改法(端云必须一致):新增 `isVersionQuery`(query各参数值全纯数字才算版本号,排除随机参数如?t=时间戳/?token=xxx 防缓存爆炸);isHashedAsset 对带版本号query的资源返回可缓存,缓存key保留query(版本变=新URL=重拉,等效hash)。**后端 cache-builder.js**(isVersionQuery+isHashedAsset+sameOriginPath保留query+mimeOf剥query+资源发现处 `pathOnly=p.split('?')[0]` 再判.js/.css扩展名)、**端侧 WebCacheManager.ets**(isVersionQuery+isHashedAsset 同款逻辑)两边都改。
- 结果:K11 改 bundle:true,离线包 4个资源1.6MB,真机浮窗"K11 包4/4"。**通用能力**:后面任何用版本号query的站都受益。**注意**:改 isHashedAsset 这类端云一致判断,两边必须同步改+真机验证浮窗"包N/N"(见 TROUBLESHOOTING.md 端云一致铁律)。

**后台产品化 + 每应用精细配置(2026-06-18,端云闭环,真机验证)**
- **后台 detect API**:`POST /api/admin/apps/detect`(index.js)调 cache-builder.js 导出的 `detectSite(url)`——抓首页HTML→判类型(next/vite/cra/other)+抽title当名称+找icon+数同源可缓资源+给建议加速参数(动态站 swrDoc+prerender;有同源可缓资源才 bundle:true;Next才 codeCache+prefetch)。注:cache-builder.js 的 main() 已改成只在直接CLI运行时执行(`isDirectRun` 判断),被 import 时不跑,否则误读 argv。
- **Apps.vue 升级**:URL行加"一键探测"按钮(detect回填名称/建议参数)、表格加"离线包状态"列(已建N个/XKB、待构建、不启用,数据来自 GET /api/admin/bundles)、表单加"额外黑名单"textarea + "chunk预取"checkbox、保存后若开bundle未建弹窗"一键构建"。
- **每应用精细配置端云闭环**:RemoteApp 加 `extraBlockHosts?:string[]`(每应用额外黑名单,叠加全局)+ `prefetchChunks?:boolean`(每应用预取开关覆盖)。端侧 WebCacheManager 加 `applyApps(apps)`:按 origin 预算"全局+该应用额外"的合并黑名单存 mergedBlockByOrigin、预取开关存 prefetchByOrigin;isBlocked 改用 blockListFor(url)(按 origin 取合并列表);prefetchSiteChunks 按 origin 优先用应用覆盖值。WebAccel.ets 三处配置注入(init/refresh回调/手动refresh)在 setBlockHosts 后都加了 `webCache.applyApps(remoteConfig.getApps())`。真机验证 `applyApps: 3 origins`,Booking 额外黑名单(otel-gw/sink.gw等)生效且只对 booking origin,页面功能正常。

**离线包自动更新(2026-06-22,定时一天一次)**
- 需求:网站源站更新/出错时自动检测+重建离线包,不用人工点。`admin/server/index.js` 用 Node 内置 setInterval(无新依赖):`runAutoUpdateOnce()` 遍历所有 bundle:true 的站 → check → changed 就 update → update失败 fallback `buildWithRetry`(build重试3次,5s/10s退避)→ 一个站失败不影响其它。`AUTO_UPDATE_INTERVAL_MS=24h`、启动后1min先跑一次、`autoUpdateRunning`防重叠、结果写 `data/auto-update-log.json`。API:`POST /api/admin/auto-update/run`(手动触发)、`GET /api/admin/auto-update/log`(查结果)。已验证:k11 update OK、beacukai fetch failed 被捕获不影响 k11、防重叠生效。注意变量声明在 runCacheBuilder 后(避免TDZ)、函数在文件末尾(声明提升)。端侧自愈已较完整(坏缓清理、SWR版本校验、版本门),不强改。

**后端(纯配置,端侧零改动):**
- `admin/server/data/config.json`:三站配置;apps顺序=K11/印尼入境卡(前2优先预渲染)/Booking;settings.bundleConcurrency=12;blockHosts含Booking遥测域。
- `admin/server/cache-builder.js`:isHashedAsset 加 `.endsWith('.map')` 排除 sourcemap(减小离线包,零风险)。
- 印尼入境卡(beacukai)离线包已建(`node cache-builder.js build beacukai`,本机直连政府站OK),39文件1.8MB,真机下到54条。

### 当前实测数据(优化后,稳定可演示)
- 冷启动 e2e 430~473ms;印尼入境卡FCP 136ms(离线包)、K11 ~410ms、Booking ~1100ms(源站天花板)。点进应用/翻页=预渲染秒开无卡顿。
- 存储:HAP装机包412KB;后端离线包1.8MB(仅beacukai);真机沙箱7.7MB/72条(64MB上限+LRU)。

### 关键结论:加载这块端侧代码已到位,不要再激进改
工作流分析结论(task wydxglm7q):端侧已秒开,cacheMode改PREFER_CACHE=高风险不做;并发/节流/预渲染排序都走**后台 settings/apps 顺序**调即可(端侧零改动)。**"更快"的剩余空间在后台配置层,不在端侧代码——别为有限收益冒险改端侧。**

### 还没做的(用户提过,优先级在后,按需推进)
1. **出对照报告文档**给周一评审:三站优化前后数据 + 框架能优化的 vs 源站/网络天花板。
2. **离线包 gzip**:已搁置。HarmonyOS @ohos.zlib 无 gzip 内存解压API(只能走临时文件笨路,多磁盘IO可能反拖慢),当前离线包本就不大,性价比低。要做优先用**传输层 gzip**(后端对 /bundles 开 gzip,端侧零改动)。
3. **管理平台更好用 + 每应用精细配置**(支撑上架几十个):工作流方案已出(detect一键探测上架、RemoteApp加extraBlockHosts/prefetchChunks做每应用黑名单/精细配置)。用户说"按推荐慢慢做"。

详见用户记忆:`harm-youhua-test-plan`、`harm-youhua-build-on-this-machine`、`harm-youhua-perf-report-findings`。
