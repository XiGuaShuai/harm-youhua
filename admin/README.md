# youhua-admin —— 网页加速方案的远程配置 + 离线包服务

配套 `app/`(鸿蒙元服务「网页应用集合」,经 `webaccel` SDK 接入)的**后台**:让端侧不用每次改个应用/黑名单/离线包就重新发版,
而是开机从这台服务器拉配置;离线包也放这台服务器让端侧下载到应用沙箱(不打进 HAP)。

```
youhua-admin/
├── server/   Node + Express:配置 API + 离线包托管 + 一键服务端打包
└── web/      Vue3 + Vite + Element Plus + Pinia:后台管理界面
```

## 跑起来

```bash
# 1) 后端(端口 8787)
cd server
npm install
ADMIN_USER='<admin-name>' ADMIN_PASS='<strong-password>' npm start
#   → http://localhost:8787/api/config      鸿蒙 App 拉这个
#   → 首次启动用 ADMIN_USER / ADMIN_PASS 创建账号；之后读取 data/users.json，不把账号密码写进仓库

# 2) 后台界面(端口 5174,开发时自动代理到 8787)
cd web
npm install
npm run dev
#   → http://localhost:5174   用账号密码登录
```

## 后端能管什么(都适配当前方案)

| 后台页面 | 对应端侧(webaccel SDK) | 作用 |
|---|---|---|
| 应用管理 | `WebAccel.getApps()` / launcher 列表 | 增删网页应用、每个 app 的加速开关、路由列表 |
| **更新 JSON** | SDK / 宿主读取的 `configJson` | 按应用 + 环境一键从运营后台拉最新 JSON；覆盖该应用绑定的全部地区 |
| 过滤黑名单 | SDK 注入的 `blockHosts` | 被墙第三方域名,端侧命中即秒拒 |
| 离线包 | 下载进接入方应用沙箱(不打进 HAP) | 服务端构建/手动导入静态资源,生成 manifest 并托管给端侧 |
| configJson 自动同步 | 第三方后台登录 + 配置接口 | 启动时立即执行，之后每 60 秒按 `appId + environment` 独立登录并写回对应配置，单请求 20 秒超时 |
| 全局设置 | 沙箱上限 / 离线包下载并发等 | (`字节码开关` 字段在元服务被忽略,平台不支持) |

### 2026-10-08/09 相关运维

测试环境四应用离线包（beacukai / Europcar / Australia / 哈利法塔）已更新，用户先自测；细节见 [`../../测试环境四应用离线包更新-2026-10-08.md`](../../测试环境四应用离线包更新-2026-10-08.md)。未授权不要同步到 pre/prod。

### 更新 JSON 独立页（2026-10-08）

侧栏菜单「更新 JSON」，路由 `#/config-json`。线上入口：

```text
测试：https://maidun.chujingservice.com/test#/config-json
预发：https://maidun.chujingservice.com/pre#/config-json
正式：https://maidun.chujingservice.com/prod#/config-json
```

操作口径：

1. 先选环境（`/test`、`/pre`、`/prod` 路径会锁定对应环境）。
2. 点某个应用的「更新此应用」：只刷 **当前环境** 这一份 `configJson`。
3. 该应用若绑定多个地区（如 XE 18 个地区），共用这一份 JSON；一次更新等于覆盖该应用全部地区。
4. 「更新当前环境全部」会刷当前环境所有已配置同步源的应用。
5. 成功但内容没变时也会刷新 `configJsonSyncedAt`，页面显示「已检查，无变化」。
6. 端侧不会实时强推；设备需重开应用、等 `configRefreshSec` 轮询，或调用 `WebAccel.refreshConfig()`。

前端源码：`admin/web/src/views/ConfigJson.vue`。应用管理页原有行内「更新 JSON」按钮仍可用，行为与本页一致。

## 关键接口

对外系统接入应用、配置 JSON、地区和离线资源时，使用只允许 `test` 环境的
[`INTEGRATION_API.md`](./INTEGRATION_API.md)。该接口使用独立令牌，不复用后台登录会话。

- `GET /api/config` —— **鸿蒙 App 开机拉取**:`{ version, apps, blockHosts, settings }`
- `GET /bundles/<id>/manifest.json` —— 离线包(格式与 App 的 rawfile manifest 一致:`[{url,file,mime}]`)
- `POST /api/admin/bundles/<id>/build` —— 服务端为某 app 打包(后台「服务端打包」按钮)
- `POST /api/admin/bundles/<id>/import` —— 手动导入指定静态资源 URL,立即下载并重生成 manifest/压缩 manifest
- `POST /api/login` —— 账号密码登录,返回会话 token;后续管理请求带 `X-Admin-Token: <token>` 头
- `POST /api/admin/config-json-sync/run` —— 手动触发某个 app 的 `configJson` 同步(或全量同步)
- `GET /api/admin/config-json-sync/status` —— 当前同步健康状态（失败/卡住/过期）
- `GET /config-json-sync.html` —— 浏览器查看同步状态，每 20 秒刷新
- `GET /config-json-sync-banner.js` —— 管理页底部状态横条
- 应用/黑名单/设置的增删改:`/api/admin/*`(需 `X-Admin-Token` 头);改密 `POST /api/admin/password`

## 鸿蒙端怎么接(已完成,经 webaccel SDK)

端侧已通过 `app/webaccel` SDK 接入本后台,一行 `WebAccel.init(ctx, { configServer })` 即可:

1. **开机拉配置**:SDK 内部请求 `https://你的服务器/api/config`,把 `apps`、`blockHosts`、`settings`
   分别注入 launcher 列表 / 缓存黑名单 / 全局设置。配置缓存到沙箱,拉取失败用上次的(或直供兜底)。
2. **离线包下载**:SDK 对 `bundle:true` 且已有 manifest 的站点,从 `/bundles/<id>/manifest*.json` 下载该站离线包到沙箱
   (缓存 key = 原站 URL),**改资源不用重发 App**,且不计入元服务包体。
3. 后台重建离线包后会生成新版本号;端侧重新打开应用或调用 `WebAccel.refreshConfig()` 后拉到新版本并下载新增/变更资源。

## `configJson` 自动同步(后台应用 JSON)

有些站点的 H5 配置不是人工上传,而是第三方后台接口返回的 `configJson`。这类站点在 admin 里配置 `configJsonSync`,由后台定时同步到本地 `configJson` 字段,再一起下发给端侧。

同步链路如下:

1. 先调用第三方登录接口拿 token,例如:

   - `POST https://meta-manage.hssstg.com/admin-api/login`
   - 响应里的 token 字段: `token`

2. 再调用配置接口拿应用 JSON,例如:

   - `GET https://meta-manage.hssstg.com/admin-api/api/webappconfig/getList?pageNum=1&pageSize=10&appId=1930101295172853761`
   - 目标 JSON 路径: `data.records[0].configJson`

3. `getWebNameList` 不是 configJson 来源,它只是应用列表接口。

4. 后台启动时立即执行同步，之后每 60 秒为每个应用/环境独立执行一次;当前已配置同步源的应用会按测试、预发、正式环境分别刷新 `configJson`，单个失败不阻塞其它应用。也可以在「更新 JSON」页手动点，或调 `POST /api/admin/config-json-sync/run`（`{ appId, environment }`）立即刷新。单目标 25 秒超时；并发 6；失败或卡住会自动再拉（单目标最多 3 次，整轮最多再跑 3 轮）。成功拉取后无论内容是否变化都会刷新 `configJsonSyncedAt`。

   线上环境必须使用服务器自身可访问的配置读取接口。2026-09-04 测试运营域名解析失败见 [`后台运维记录-2026-09-04.md`](../后台运维记录-2026-09-04.md)。2026-09-07 正式环境锁死跳过见 [`后台运维记录-2026-09-07.md`](../后台运维记录-2026-09-07.md)。

5. 日常按应用操作优先用管理页「更新 JSON」：`/#/config-json`。整轮健康状态仍看 `GET /config-json-sync.html`（需登录）和 `GET /api/admin/config-json-sync/status`。详细 `config-json-sync-log.json` 每轮删除。

6. 端侧不需要新增任何必须接入的 API,还是按 `/api/config` 和 `WebAccel.refreshConfig()` 这条链路拿到最新配置。

7. 数据模型仍是「一应用 + 一环境 = 一份 configJson」。地区只表示适用范围，不是按地区各存一份 JSON。

同步账号不得写入仓库文档、示例代码或提交记录。测试、预发、生产即使共用登录账号，`configJson`、业务 appId 和读取接口仍必须按环境隔离。

> 接入与元服务注意事项见 `app/webaccel/README.md`、维护流程见 `app/UPDATE.md`。
> 动态接口(跨境实时数据)仍由你的**后端镜像**解决,与本配置服务可以是同一台服务器。

## 数据/存储

- 本地开发配置存 `server/data/config.json`。线上有效配置在服务器/Docker 运行环境中,不要只改本地文件。
- 离线包存 `server/bundles/<id>/`,通过 `/bundles` 静态托管。
- 生产部署:`server` 用 pm2/systemd 常驻;`web` 跑 `npm run build` 出静态文件,用 nginx 托管并反代 `/api`、`/bundles` 到 server。

## 更新日志

### 2026-06-05 —— 后台升级为正式管理系统

- **登录鉴权**:从「单一 token」改为**账号 + 密码**登录。密码用 scrypt 加盐哈希存 `data/users.json`(不存明文);登录后颁发会话 token 存 `data/sessions.json`,有效期 7 天,服务重启不掉线。
- **修改密码**:新增 `POST /api/admin/password`,登录后在后台右上角用户菜单即可改。
- **初始账号**:首次启动必须通过环境变量 `ADMIN_USER` / `ADMIN_PASS` 设置，密码仅以 scrypt 哈希写入运行数据；原 `ADMIN_TOKEN` 降级为可选的「脚本主令牌」，默认不开启。
- **界面美化**:全新分栏登录页;新增「概览」仪表盘(统计卡 + 应用速览 + 系统信息);侧边栏改深色带图标、当前项渐变高亮;顶栏加配置版本标签与用户头像下拉(改密 / 退出);统一品牌主色与卡片样式。
# 全环境备份入口（2026-09-21）

测试、预发、生产全部应用配置和资源，连同本后台页面显示产物、账号、数据库和部署资料，统一备份到工作区本地 `bar/20260921-full-recovery`。服务器不额外生成运维备份副本。恢复范围、校验及新服务器操作见 [`../BACKUP_RESTORE.md`](../BACKUP_RESTORE.md)；旧五应用备份只作阶段快照。
