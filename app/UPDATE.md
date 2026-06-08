# 更新维护指南(元服务 + SDK 版)

本工程现在是**鸿蒙元服务(Atomic Service)**:`entry` 通过 `webaccel` HAR SDK 接入「网页应用集合」的多层加速。
本文说明**网站更新、增删应用、改配置时该做什么**,以及**什么时候才真的需要重新发版**。

---

## 一、现在的架构(读这一段就够)

- `app/webaccel/` 是加速能力 **HAR SDK**;`app/entry/` 是**元服务本体**(`bundleType: atomicService` + `installationFree: true`),几行代码接入 SDK。
- **纯远程模式**:不打 rawfile 内置包(元服务单包 ≤2MB),离线缓存全部运行时下载进沙箱(`filesDir`),不计包体。
- 字节码注入层(`injectOfflineResources`)被元服务平台禁用,**已移除**;其余加速层照常工作:
  - **离线缓存拦截**(内容 hash 不可变资源)—— 自愈,越用越快;
  - **主文档 SWR**(陈旧即用 + 启动校验指纹)—— 站点更新自动换新版;
  - **离屏预渲染**(BuilderNode)—— 点开秒显;
  - **全量 chunk 预取** —— 二级页面 JS 提前到本地;
  - **黑名单短路** —— 拦掉国内不可达的统计/广告/翻译,避免卡 load。
- **配置(应用列表 / 黑名单 / 设置)和离线包都来自 `admin` 后台**:开机拉配置;打开某网页应用时按需下载该站离线包进沙箱(同一 app 本次运行只拉一次)。

---

## 二、网站(如 ecd.beacukai.go.id)更新后 → 不用做任何事

- **运行时缓存**:新版本 JS 是新 hash → 新 URL → 本地没有 → 自动拉新并缓存(自愈)。
- **主文档校验**:每次启动(节流)重拉首页比指纹,变了 = 站点更新 → 覆盖缓存并刷新 WebView,用户**下次启动自动拿到新版**。

「能用」「拿到新版」都是自动的。

---

## 三、离线包要更新得更快 → 在 admin 后台点「服务端打包」

离线包(首页 + 各路由 chunk)由后台托管。网站大改后想让二级页面更快:

1. 进 `admin` 后台 → 应用管理 → 对目标 app 点一次**服务端打包**(重抓最新 chunk)。
2. 完事。App **下次打开该网页应用时自动下最新离线包进沙箱**,无需重新发版。

> 没点也能用:运行时缓存会在用户点进去时自愈,只是首次稍慢一次。

---

## 四、增删网页应用 / 改黑名单 / 改设置 → 全在 admin 后台

在后台「应用管理 / 全局设置」改,**App 开机自动生效,无需重新发版**:

- 新增/删除应用、改名改 URL、是否启用离线包;
- 过滤黑名单(被墙第三方);
- 缓存上限 / 主文档校验节流。

> 不依赖后台也行:`WebAccel.init(ctx, { apps: [...] })` 直供列表(纯本地模式,不下离线包,靠运行时缓存自愈)。

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

1. **不增包体**:不要打 rawfile 内置包;缓存只走运行时沙箱。当前签名 HAP ≈ 308KB,元服务单包上限 2MB、总计 10MB。
2. **不碰元服务禁用 API**:`injectOfflineResources` / `webview.OfflineResourceType` / `OfflineResourceMap`(字节码注入整层)在元服务编译期就报错,别加回来。

接入代码就三处:`WebAccel.init` → `WebAccel.attach` + `WebAccel.prewarm` → `WebAccelView`。详见 `webaccel/README.md`。

---

## 七、动态接口(跨境实时数据)

这部分端侧缓存不了(动态),由后端镜像/中转解决:把动态请求指向你国内的快服务器,应用列表 URL 填镜像域名即可,缓存 + 黑名单照常生效。风控(源站反爬/登录态)是后端侧的事。

---

> 历史:本工程原为普通独立 App,曾用「rawfile 内置包 + 重打 HAP」离线方案。改造为元服务后该方案已废弃(`tools/refresh-offline-bundle.sh` 不再使用),离线资源统一由 admin 后台下发、运行时进沙箱。
