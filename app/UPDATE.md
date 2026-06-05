# 更新维护指南

本工程是「网页应用集合」HarmonyOS App,内置了多层加速(离线缓存 / 内置包 / 字节码 / 离屏预渲染)。
本文说明**网站更新后、或新增页面/应用时,该做什么**。

---

## 一、最重要的认知

**网站(如 ecd.beacukai.go.id)redeploy 后,App 功能上不会坏,也不用你立刻做任何事。**

- **运行时沙箱缓存**:新版本的 JS 是新 hash → 新 URL → 本地没有 → 自动从网络拉新版并缓存(自愈)。
- **主文档版本校验**:每次启动(60s 节流)重拉首页 HTML 比对指纹,变了 = 站点更新 → 覆盖缓存并刷新 WebView → 用户**下次启动自动拿到新版**。

所以「能用」是自动的。你要做的只是**保持「首启即秒开 + 字节码加速」的最佳速度** —— 因为这两项依赖**内置包**,而内置包是打包那一刻冻结的,不会自动更新。

| 层 | 站点更新后 | 需要你手动? |
|---|---|---|
| 运行时沙箱缓存 | 自动拉新 | ❌ 自愈 |
| 主文档版本校验 | 自动刷新换新版 | ❌ 自愈 |
| 内置包(首页 HTML + 全部 chunk) | 冻结不更新 | ✅ 重跑脚本 + 发版 |
| 字节码缓存 | 跟随内置包 | ✅ 同上 |

---

## 二、网站更新后,刷新内置包(3 步)

```bash
# 1. 刷新内置包:自动重抓首页 HTML + 全部路由的 chunk(适配新 hash),写入 rawfile + manifest
bash tools/refresh-offline-bundle.sh

# 2. 重新构建 HAP(或在 DevEco Studio 里点 Build)
#    命令行(需 DevEco 自带 hvigorw 在 PATH):
hvigorw --mode module -p module=entry@default -p product=default assembleHap

# 3. 签名后发布 / 安装
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

脚本会**同一次抓取**首页 HTML 和所有 chunk,保证它们是同一个 build、不会版本错配。

---

## 三、新增「网站的页面/路由」

网站加了新的二级页面(例如 `/forms/bc99`):

1. 编辑 `tools/refresh-offline-bundle.sh`,在顶部数组加一行:
   ```bash
   ROUTES=("/" "/forms/bc22" "/forms/bc32" "/forms/bc34" "/forms/bc99")
   ```
2. 重跑脚本 + 重新构建发版(见第二节)。

> 不加也能用(运行时缓存会在用户第一次点进去时缓存),只是首次进新页面会慢一次。

---

## 四、新增「网页应用」

在 App 里挂一个新的网页应用:

1. 编辑 `entry/src/main/ets/pages/Index.ets`,在 `apps` 数组加一行:
   ```ts
   private apps: WebApp[] = [
     { name: '印尼海关 e-CD', url: 'https://ecd.beacukai.go.id/' },
     { name: '某某系统',      url: 'https://xxx.example.com/' },   // ← 加这行
   ];
   ```
2. 重新构建发版。

> 普通网页应用**不需要打包内置**,靠通用层(离线缓存 + 黑名单 + 预连接)自动加速,越用越快。
> 只有少数高频「招牌应用」才值得做内置包(需为它单独写一份 refresh 脚本,改脚本里的 `BASE` 和 `ROUTES`)。

---

## 五、发版前检查

- `entry/.../pages/WebPage.ets` 里 `@State showDebug` 设为 `false`(关掉右上角调试浮层)。
- 通用过滤黑名单在 `entry/.../cache/WebCacheManager.ets` 的 `BLOCK_HOSTS`(被墙第三方,可增删)。
- 字节码缓存开关:`entry/.../webview/WebShared.ets` 的 `ENABLE_CODE_CACHE`(默认 true)。

---

## 六、动态接口(跨境实时数据)

这部分 App 端缓存不了(动态),由你后端镜像/中转解决:把动态请求指向你国内的快服务器,
App 端的应用列表 URL 填镜像域名即可,缓存 + 黑名单照常生效。风控(源站反爬/登录态)是后端侧的事。
