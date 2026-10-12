# 更新维护指南(元服务 + SDK 版)

本工程现在是**鸿蒙元服务(Atomic Service)**:`entry` 通过 `webaccel` HAR SDK 接入「网页应用集合」的后台离线包方案。
本文说明**网站更新、增删应用、改配置时该做什么**,以及**什么时候才真的需要重新发版**。

---

## 2026-07-02 当前口径

当前 SDK 定版为“后台离线包 + 端侧拉包 + WebView 本地命中”:

- 不做端侧运行时静态资源自动缓存。
- 不做主文档 SWR。
- 不做离屏预渲染。
- 不做 chunk 预取。
- 后台更新离线包后,端侧需要重新打开应用或调用 `WebAccel.refreshConfig()` 才会拉新版本。
- 后台某些站点的 `configJson` 由第三方接口自动同步,不是人工上传到 SDK;端侧仍然只认 `/api/config`。

如果其他历史记录仍出现运行时缓存自愈、SWR、预渲染等描述，以本节和根目录 `SDK_OFFLINE_BUNDLE.md` 为准。

测试、预发和生产环境均已提供独立对外集成 API，由调用方维护应用、地区、配置 JSON 和离线资源。三个环境使用不同路径和令牌，数据与物理离线包互相隔离。详见 `../对外接口交互文档.md`。

---

## 一、现在的架构(读这一段就够)

- `app/webaccel/` 是 **HAR SDK**;`app/entry/` 是**元服务本体**(`bundleType: atomicService` + `installationFree: true`),几行代码接入 SDK。
- **纯远程离线包模式**:不打 rawfile 内置包(元服务单包 ≤2MB),离线包由后台托管,端侧下载进沙箱(`filesDir/webcache`),不计包体。
- 字节码注入层(`injectOfflineResources`)被元服务平台禁用,已移除。
- 当前只保留:
  - 后台 `/api/config` 下发应用列表、黑名单、离线包地址和版本号。
  - SDK 对 `bundle:true` 站点下载后台离线包。
  - WebView 请求原站 URL 时由 SDK 拦截并命中本地离线包。
  - 黑名单短路,拦掉国内不可达或低价值第三方请求。
- 当前不保留:运行时静态资源自动缓存、主文档 SWR、离屏预渲染、chunk 预取。

---

## 二、网站资源更新后 → 后台重建离线包

如果源站 JS/CSS/字体 URL 变化,需要后台重新构建或手动导入新的静态资源。端侧不会自己把用户访问过的新资源写入缓存。

后台离线包更新后,端侧需要重新打开应用或调用 `WebAccel.refreshConfig()` 才会发现新版本并下载。

## 二补、网站 `configJson` 更新后

接口托管应用通过 `PUT /api/integration/v1/:environment/apps/:id/config-json` 上传 JSON。后台“配置 JSON”页面只展示上传状态和内容，不负责人工编辑。

原有非接口托管应用仍可使用 `configJsonSync` 从第三方后台定时同步：

如果这个站的 H5 配置 JSON 不是你手工填,而是第三方后台生成,就不要往 SDK 里手动上传。

做法是:

1. 在 admin 里给该 app 配好 `configJsonSync`。只要填了登录/配置接口，后台会自动纳入定时同步。
2. 后台启动时立即登录第三方管理系统，之后每 60 秒按测试、预发、正式环境分别自动同步。
3. 先拿登录 token,再调配置接口,把返回里的 `data.records[0].configJson` 写回后台 app 配置。
4. 端侧按 `configRefreshSec` 周期拉 `/api/config`,或者手动调用 `WebAccel.refreshConfig()` 后就能拿到新 JSON。

示例接口:

- 登录: `POST https://meta-manage.hssstg.com/admin-api/login`
- 配置: `GET https://meta-manage.hssstg.com/admin-api/api/webappconfig/getList?pageNum=1&pageSize=10&appId=1930101295172853761`
- token 字段: `token`
- JSON 路径: `data.records[0].configJson`

---

## 三、离线包更新

离线包由后台托管。接口托管应用应通过目标环境集成 API 上传资源内容，或提交 URL 让服务端导入；网页只控制是否向对应环境设备下发。原有应用仍可使用后台已有的构建/导入能力。

网站大改后：

1. 调用目标环境集成 API 更新应用资源；原有非接口托管流程才从 `admin` 后台构建或导入。
2. 确认目标环境后台显示正确的资源数量，并按需要打开“下发”。
3. 后台重新生成 `manifest.json` / `manifest.zz.json` 和版本号。
4. 端侧重新打开应用或调用 `WebAccel.refreshConfig()` 后下载新离线包。

未进入离线包的资源仍会走网络,但不会被端侧运行时自动缓存。

---

## 四、应用、黑名单和设置

三个环境的接口托管应用、地区和 JSON 由各自环境的集成 API 修改，后台网页只查看状态和控制离线资源下发。当前不修改黑名单机制，也不修改 HAR。

原有配置通过后台修改后，**App 开机自动生效，无需重新发版**：

- 应用信息和是否启用离线包；
- 过滤黑名单(被墙第三方);
- 沙箱上限 / 离线包下载并发。

> 不依赖后台也可以用 `WebAccel.init(ctx, { apps: [...] })` 直供列表，但纯本地模式没有后台 manifest，不会下载离线包。

---

## 五、什么时候才需要重新发版(重打 HAP)

只有改**端侧代码**时才需要,内容/配置类改动都不需要:

- 改了 SDK 代码(`webaccel/`)或元服务壳(`entry/` 的页面/Ability);
- 流程:DevEco 打开 `app/` → **Sync** → 构建 → **元服务签名** → 上架/安装。

```bash
# 命令行构建(DevEco 自带 hvigorw 在 PATH 时)
hvigorw assembleHar -p module=webaccel@default          # 可选:单独产出 SDK 的 .har
hvigorw --mode module -p module=entry@default -p product=default assembleHap
```

> 首次需在 DevEco 配置**元服务类型签名**(`File > Project Structure > Signing Configs` 自动签名,登录已开通元服务的华为账号)——普通 App 证书不可用于元服务。

---

## 六、改 SDK 代码时务必守住的两条红线

1. **不增包体**:不要打 rawfile 内置包;后台离线包只在运行时落到接入方应用沙箱。当前签名 HAP ≈ 308KB,元服务单包上限 2MB、总计 10MB。
2. **不碰元服务禁用 API**:`injectOfflineResources` / `webview.OfflineResourceType` / `OfflineResourceMap`(字节码注入整层)在元服务编译期就报错,别加回来。

推荐接入只需要 `WebAccel.init` + `WebAccelLauncher`。自定义壳再使用 `WebAccelView`。详见 `webaccel/README.md`。

---

## 七、动态接口(跨境实时数据)

这部分端侧缓存不了(动态),由后端镜像/中转解决:把动态请求指向你国内的快服务器,应用列表 URL 填镜像域名即可,缓存 + 黑名单照常生效。风控(源站反爬/登录态)是后端侧的事。

---

> 历史:本工程原为普通独立 App,曾用「rawfile 内置包 + 重打 HAP」离线方案。改造为元服务后该方案已废弃(`tools/refresh-offline-bundle.sh` 不再使用),离线资源统一由 admin 后台下发、运行时进沙箱。
