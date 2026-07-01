# CLAUDE.md — 项目导航（给新对话快速上手）

> 本文件让任何新对话快速熟悉这个项目并继续迭代。先读这里，再下钻子目录 README / TROUBLESHOOTING.md。
> **读完这份就能上手。** 最后两节「迭代指南」「踩坑铁律」尤其重要——避免重复踩坑。

---

## 一、这是什么

`youhua-mono` —— 「网页应用集合」**鸿蒙加速方案**单仓库。目标：把一批网页应用（K11、印尼入境卡、Booking 等）包进**鸿蒙元服务(免安装)**，靠多层加速做到「点开秒显」；配一个**后台**让应用列表/加速参数/离线包**远程下发、改东西不用重新发版**。

```
用户点图标 → 元服务(免安装, 装机包~260KB) → 多层加速的 ArkWeb 网页 → 秒开
                    ↑ 开机拉 /api/config、按需下离线包
               后台(配置 + 离线包托管 + 定时自动更新)
```

**两条产品线：**
1. **端侧 SDK（webaccel HAR）**——加速能力库，一套逻辑所有应用共用。**给别的鸿蒙工程集成用**（这是核心交付物）。
2. **后台（admin）**——Node+Express 配置/离线包服务 + Vue3 管理界面，集中管理所有接了 SDK 的 App。

---

## 二、仓库结构

```
youhua-mono/
├── app/                鸿蒙元服务工程(DevEco/hvigor 构建)
│   ├── webaccel/       ★ 加速 SDK(HAR)—— 所有加速逻辑在这
│   └── entry/          元服务本体 HAP(几行代码消费 webaccel)
├── admin/              后台
│   ├── server/         Node+Express(配置 API + 离线包 + 定时自动更新)
│   └── web/            Vue3+Vite+ElementPlus+Pinia 管理界面
├── deploy/             部署脚本/nginx 配置
├── docker-compose.yml  后台编排(admin + mysql 容器)
├── DEPLOY.md           部署/运维
└── TROUBLESHOOTING.md  联调踩坑(改加速前必读)
```

**端↔后台**：元服务开机拉 `/api/config`(应用/黑名单/设置)，打开网页按需下离线包进沙箱(自愈缓存)；后台改配置/打包，端侧下次启动即生效，**不重新发版**。

---

## 三、app/ — 鸿蒙元服务工程（两层：webaccel HAR + entry HAP）

### 关键文件
| 文件(相对 app/) | 职责 |
|---|---|
| `AppScope/app.json5` | `bundleType:"atomicService"` ★元服务声明 + bundleName |
| `entry/.../module.json5` | `installationFree:true` + 权限(INTERNET / 定位) + 网络安全配置 |
| `entry/.../EntryAbility.ets` | `WebAccel.init()` 一行初始化 + 申请定位权限 + FALLBACK_APPS 兜底 |
| `entry/.../pages/Index.ets` | 入口页:`WebAccelLauncher()` 一行 |
| **`webaccel/.../WebAccel.ets`** | ★门面 API(init/prewarm/refreshConfig/setDebug 等) |
| `webaccel/.../WebAccelLauncher.ets` | 开箱即用整页组件(列表+导航+网页+调试浮窗) |
| `webaccel/.../WebAccelView.ets` | 网页展示组件(占位 + 离线进度条,进度条有超时收起) |
| **`webaccel/.../core/WebCacheManager.ets`** | ★核心:onInterceptRequest 拦截 + LRU缓存 + 主文档SWR + 黑名单(全局+每应用) + 离线包增量 + 路由预取 + 众包 |
| `webaccel/.../core/WebPreRender.ets` | 离屏预渲染池(BuilderNode,只热预前2个) + 路由预取触发 |
| `webaccel/.../core/WebShared.ets` | Web 统一配置 buildWeb(含 onGeolocationShow 定位授权) + ViewModel(占位绑FCP/进度85%) |
| `webaccel/.../core/RemoteConfig.ets` | 远程配置:拉 /api/config、RemoteApp 接口(含 extraBlockHosts/prefetchChunks) |
| `webaccel/build-profile.json5` | ★`CONFIG_SERVER` 后端地址(debug段/release段各一) |

### SDK 门面 API
`init(ctx,options?)` · `prewarm(url,swrDoc?)` · `refreshConfig()` · `setDebug(on)` · `stats()`；组件 `WebAccelLauncher()` / `WebAccelView({url})` / `WebAccelDebugBadge`。
**RemoteApp 每应用开关**：`swrDoc`/`prerender`/`bundle`/`routes`/`codeCache`/`extraBlockHosts`(每应用额外黑名单)/`prefetchChunks`(每应用预取开关)/`manifestUrl`/`bundleVersion`。

### 构建（在本机命令行，见下方"本机编译"节）
```
hvigorw assembleHar -p module=webaccel@default -p buildMode=release   # 出 SDK(HAR)
hvigorw --mode module -p module=entry@default -p product=default -p buildMode=release assembleHap  # 出元服务 HAP
```

### 元服务硬约束（改 app/ 前必记）
- **单包≤2MB / 总≤10MB**，不打 rawfile 内置包，离线资源运行时下载进沙箱。
- **元服务签名**需 DevEco 登录已开通元服务的华为账号自动签名，普通 App 证书不行。
- **SDK(HAR)不需要签名**——给别人用只给 .har，对方用他自己的签名打他的 App。
- **API 版本**：当前 SDK 编译为 **API 15**(`compatibleSdkVersion:15`,在 app/build-profile.json5 products)，接入方需 API 15+。

---

## 四、admin/ — 后台（Node+Express+Vue3）

后端 8787(同源托管前端)，Vue 开发时 5174 代理到 8787。

| server/ 文件 | 职责 |
|---|---|
| **`index.js`** | Express 入口:所有 API、鉴权、`runCacheBuilder`、**定时自动更新**(runAutoUpdateOnce)、detect API |
| **`cache-builder.js`** | 离线包构建(check/update/build/manifest 四模式) + `detectSite`(探测站点类型) + 版本号query可缓存 + 剔sourcemap |
| `consensus-builder.js` | 众包共识建包(djb2 复算防投毒) |
| `db.js` | MySQL 连接池(votes 表，众包用；连不上不影响配置/离线包) |
| `data/config.json` | 配置持久化(apps+blockHosts+settings)，后端读文件即生效。**线上生效的这份在 docker 数据卷,不在 git;改它见第五节"改配置只改线上"** |
| `bundles/<id>/` | 离线包托管 |

**关键 API**：`GET /api/config`(端侧拉) · `/bundles/<id>/...` · `POST /api/login` · `POST /api/report`(众包)。
后台管理(需 X-Admin-Token)：`PUT /api/admin/{apps,blockhosts,settings}` · `POST /api/admin/apps/detect`(一键探测) · `POST /api/admin/bundles/:id/{check,update,build,manifest,import}` · `PUT /api/admin/bundles/:id/resource`(资源开关) · `POST /api/admin/auto-update/run`(手动触发自动更新) · `GET /api/admin/auto-update/log`(查结果)。

**web/ 视图**：Dashboard / Apps(应用增删改+探测+离线包状态列+每应用黑名单/预取) / Blocklist / Bundles(离线包操作+自动更新UI) / Settings。

### 本地起后台
```
cd admin/server && npm install && npm start   # 8787
cd admin/web && npm install && npm run dev     # 5174
```

---

## 五、部署与环境（重要）

### 线上后台（生产）
- 服务器 **`47.236.73.89`**(主机名 meta-proxy1)，Docker 跑 `youhua-admin`+`youhua-mysql`，nginx 反代 → 域名 **`https://maidun.chujingservice.com`**。
- **部署 = git push 自动部署**：裸仓库 `/srv/youhua.git`，工作树 `/srv/youhua`，push main → 自动 `docker compose up -d --build`。
- 数据卷(换代码不丢)：`youhua_admin-data`(config.json) / `youhua_admin-bundles`(离线包) / `youhua_admin-mysql`。
- **后台只用 admin/**，不编译 app/。所以部署只需 admin/ 改动；app/ 端侧改动推上去仅存档、不影响线上。
- 登录：界面 admin / 密码在服务器 `/srv/youhua/.env` 的 `ADMIN_PASS`。

#### ⭐ 改配置 / 新增应用 = 只改线上,不动本地(铁律)
**生效的 `config.json` 在 docker 数据卷里,不在 git 仓库。** 仓库里 `admin/server/data/config.json` 是过时副本,改它推 git **不会**覆盖生效配置 —— 别拿它当基准、别往它写。标准流程:
1. **拉线上当前生效配置做基准**(绝不用本地副本):`curl -s https://maidun.chujingservice.com/api/config`
2. 构造新的**整份** config，`node -e "require('./x.json')"` 校验是合法 JSON。
3. SSH 进服务器换容器内文件(`yuan` 读不了数据卷目录但能跑 docker,故走 `docker exec`/`docker cp`)：
   ```bash
   ssh -i ~/.ssh/youhua_deploy yuan@47.236.73.89   # 容器名 youhua-admin
   # 先备份再替换(后端读文件即生效,无需重启)
   scp -i ~/.ssh/youhua_deploy x.json yuan@47.236.73.89:/tmp/c.json
   docker exec youhua-admin sh -c 'cp /app/server/data/config.json /app/server/data/config.json.bak.$(date +%s)'
   docker cp /tmp/c.json youhua-admin:/app/server/data/config.json
   ```
4. `curl` 公网 API **复验**生效；用过的本地临时文件删掉,不留工作区。
- **含中文(应用名)别用 curl PUT**(会乱码),`docker cp` 整份文件替换最稳。`id` 必须英文 ASCII(中文坏离线包 URL)。

### 本机编译（这台机 admin 用户，无独立 DevEco PATH）
```
$deveco="D:\Huawei\DevEco Studio"; $env:DEVECO_SDK_HOME="$deveco\sdk"
$env:Path="$deveco\tools\node;$deveco\tools\hvigor\bin;$deveco\tools\ohpm\bin;$env:Path"
cd D:\Work\KCP\harm-youhua\app
hvigorw.bat --mode module -p module=entry@default -p product=default [-p buildMode=release] assembleHap --no-daemon
```
- 用 **DevEco 自带 hdc**：`D:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe`（3.2.0b），不能用 `D:\hdc`。真机序列号 `2NX0123C29000677`(HUAWEI HBP-AL00, HarmonyOS 6.0)。
- **本机编译需 4 处临时适配（不进 git，git 里是干净的原值）**：① `app/build-profile.json5` 签名换成本机 `C:\Users\admin\.ohos\config\default_pin2atm_...`(借 D:\Work\Pin2eat 的签名，密码照抄其 build-profile)；② `app/AppScope/app.json5` bundleName 改 `com.atomicservice.6917596829912522753`(证书授权的)；③ `app/hvigor/hvigor-config.json5` + `app/oh-package.json5` modelVersion 6.0.1→6.0.0(本机 hvigor 只支持6.0.0)。**正式发版要用项目自己的元服务签名+原 bundleName。**
- debug 包 CONFIG_SERVER 指本地 `http://192.168.20.197:8787`(局域网调试)；release 包指线上 maidun。真机连本地后端需 module.json5 放行明文 HTTP(network_config.json，已配)。

### git
- 远程：`origin`(GitHub) + `server`(线上部署服务器)。**功能代码在 GitHub 分支 `feature/auto-update-and-optimize`**(不碰 main)；server 远程推 main 触发部署。git 身份 L-kook / 3164288669@qq.com。
- 本仓库**git 全局代理 `127.0.0.1:7896` 已坏**(502/TLS失败)；git 联网用 `git -c http.proxy= -c https.proxy= <命令>` 绕过(直连 GitHub 通)。线上 push 用部署密钥 `~/.ssh/youhua_deploy`(已配 core.sshCommand)。

---

## 六、当前状态（截至 2026-07-01）

**线上后台当前只配 3 个测试应用**(`curl https://maidun.chujingservice.com/api/config` 为准)：
- K11 香港: `bundle:true`,29资源,压缩后约5.8MB。
- 印尼出境卡(beacukai): `bundle:true`,13资源,按 `>=64KB` 或 `>=3000ms` 选择关键静态资源,压缩后约608KB。
- Booking.com: `bundle:false`,首页被 AWS WAF challenge 拦截,服务端无法构建可靠离线包;当前走运行时缓存 `bstatic.com/bstatic.cn` + Booking 遥测黑名单 + preconnect。
- 当前三站均关闭 `prerender` / `swrDoc` / `codeCache` / `prefetchChunks`,全局关闭 `bytecodeCache`,本轮只验证离线包和静态资源缓存带来的资源获取速度。

历史上曾临时加过 bilibili / michelin / translate / foodpanda / youtube / twitch / tiktok 等 7 个站点,当前线上配置已按本轮测试收敛,没有继续下发这些站点。

**历史实测达成**:冷启动 ~430ms、点进应用/翻页预渲染秒开、印尼首屏136ms(离线包)。装机包 release 258KB。**用户确认"确实快"。** 当前线上配置为排除预渲染/SWR/字节码变量,只测资源缓存链路。

**已做的功能（都真机验证、已部署线上）**：
- 端侧秒开：离屏预渲染+优先级、离线包、主文档SWR、路由预取(只下静态资源)、占位绑FCP、黑名单拦遥测。
- 版本号query资源可缓存(端云一致)——让 K11 这种 `?2025121805` 命名的资源也能离线。
- 每应用精细配置：额外黑名单(如Booking遥测域只对Booking) + 预取开关，按 origin 生效。
- 定位权限：网页"当前位置搜索"能用(module.json5 加权限 + EntryAbility 申请 + WebShared onGeolocationShow)。
- 后台：一键探测detect、Apps离线包状态列、Bundles自动更新UI。
- **离线包定时自动更新(一天一次)**：遍历 bundle:true 站 check→有更新update→失败fallback build重试3次，结果写 data/auto-update-log.json。

**交付物**：`webaccel-SDK-api15.har`(58.6KB, API15, 连线上后台, 无签名无外部依赖, 给别人集成)。

---

## 七、迭代指南（下一步可做 + 怎么做）

**还没做、按需推进**：
1. **离线包 gzip 压缩** = 已评估搁置。HarmonyOS @ohos.zlib 无 gzip 内存解压API，端侧走临时文件笨路可能反拖慢。要做优先**传输层 gzip**(后端对 /bundles 开 gzip，端侧零改动)。
2. **多租户配置**：当前所有接 SDK 的 App 共享一份后台配置。若要不同 App 显示不同站，需按 App 区分配置(新功能)。
3. **后台规模化**(上架几十个应用时)：配置内存缓存、cache-builder 并发下载、Apps 批量操作/搜索、删应用清理 bundles。
4. **端侧"更快/更小"已到位**——工作流分析结论：继续抠端侧代码收益小且有风险，剩余空间在后台配置层。LRU优化/预渲染节点上限等只在几十应用时才值得做。

**改代码的正确姿势**：
- 改加速行为/缓存 → 先读 TROUBLESHOOTING.md。
- 缓存判定改动**端云两处必须一致**：SDK `WebCacheManager.ets` 的 isHashedAsset/isVersionQuery ↔ 后端 `cache-builder.js` 的同名函数。改完真机验证浮窗"包N/N"。
- 黑名单/应用列表是**后台下发**的 → 改线上 admin 配置(界面 或 `docker cp` 换数据卷里的 config.json,见第五节),不往 SDK 硬编码加、不改 git 里的本地 config.json。
- 端侧改完要编译装真机验证(用上面本机编译命令)。后台改完重启 server。

---

## 八、踩坑铁律（血泪教训，务必遵守）

1. **永不缓存动态页的 HTML 主文档**——曾让路由预取缓 Next.js 表单页主文档(带会话状态)，导致印尼 BC32 直接 error。**预取/缓存只针对静态资源(JS/CSS/图片)，动态页 HTML 交给正常加载。** 主文档 SWR 只对入口首页。
2. **不用脚本改页面 DOM/隐藏元素**——曾注入脚本用 `[class*=loading]` 模糊匹配隐藏元素，误伤正常轮播/banner 导致三站排版错乱。治 loading 滞后只控制"框架占位何时消失"(绑FCP/进度85%)，不碰页面。
3. **不激进改缓存模式**——cacheMode 改 PREFER_CACHE 会破坏 SWR/动态内容，已否决，保持 Default。
4. **PowerShell 传中文会乱码**——curl PUT 中文到线上曾整批乱码。传中文配置用 base64 编码经 SSH，或直接写文件，别走 PowerShell+curl。
5. **源站/网络问题不是框架的锅，别瞎改**——印尼 BC32 表单 error = 源站接口返回401(curl 绕过框架也401)；Booking 同意页顿一秒 = 网站自身加载脚本。这些是天花板，框架碰不了，如实标注。
6. **本机适配文件不提交 git**——签名/bundleName/CONFIG_SERVER/hvigor版本是本机编译临时改，git 里保持原值，否则别人 clone 编译不了。

---

## 九、相关记忆（用户 memory，跨会话）
- `harm-youhua-test-plan` — 三应用测试计划+基线+实测数据
- `harm-youhua-build-on-this-machine` — 本机编译方法+适配改动
- `harm-youhua-perf-report-findings` — 性能报告问题归类+框架边界+踩坑
- `beacukai-reference-error-source-side` — 印尼BC32 error=源站401(非框架)
