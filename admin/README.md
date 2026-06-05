# youhua-admin —— 网页加速方案的远程配置 + 离线包服务

配套 `D:\youhua`(鸿蒙网页应用集合)的**后台**:让 App 不用每次改个应用/黑名单就重新发版,
而是开机从这台服务器拉配置;离线包也放这台国内服务器让 App 快速拉取。

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
npm start
#   → http://localhost:8787/api/config      鸿蒙 App 拉这个
#   → 后台登录:账号 admin / 密码 admin123  (登录后可在后台「修改密码」;或用环境变量 ADMIN_USER / ADMIN_PASS 改默认值)

# 2) 后台界面(端口 5174,开发时自动代理到 8787)
cd web
npm install
npm run dev
#   → http://localhost:5174   用账号密码登录
```

## 后端能管什么(都适配当前方案)

| 后台页面 | 对应 App 端 | 作用 |
|---|---|---|
| 应用管理 | `Index.ets` 的 `apps` 数组 | 增删网页应用、每个 app 的加速开关、路由列表 |
| 过滤黑名单 | `WebCacheManager` 的 `BLOCK_HOSTS` | 被墙第三方域名,App 命中即秒拒 |
| 离线包 | `rawfile/webcache` 内置包 | 服务端一键打包(抓首页+全部路由chunk),托管供 App 拉取 |
| 全局设置 | `DISK_CAP_BYTES` / `DOC_CHECK_MS` / 字节码开关 | 缓存上限、版本校验节流等 |

## 关键接口

- `GET /api/config` —— **鸿蒙 App 开机拉取**:`{ version, apps, blockHosts, settings }`
- `GET /bundles/<id>/manifest.json` —— 离线包(格式与 App 的 rawfile manifest 一致:`[{url,file,mime}]`)
- `POST /api/admin/bundles/<id>/build` —— 服务端为某 app 打包(后台「服务端打包」按钮)
- `POST /api/login` —— 账号密码登录,返回会话 token;后续管理请求带 `X-Admin-Token: <token>` 头
- 应用/黑名单/设置的增删改:`/api/admin/*`(需 `X-Admin-Token` 头);改密 `POST /api/admin/password`

## 鸿蒙 App 端怎么接(下一步,App 侧改动)

目前 App 把应用列表/黑名单/内置包**写死/打进 HAP**。接入本后台后改成:

1. **开机拉配置**:`EntryAbility.onCreate` 里 `http` 请求 `https://你的服务器/api/config`,
   把 `apps` 喂给 launcher、`blockHosts` 喂给 `WebCacheManager`(把 `BLOCK_HOSTS` 改成可注入)。
   配置缓存到沙箱,拉取失败用上次的(或 HAP 里的兜底)。
2. **离线包从服务器拉**:`WebCacheManager` 增加「从 `/bundles/<id>/manifest.json` 下载离线包到沙箱」,
   作为 rawfile 内置包的替代/补充 —— 这样**改资源不用重发 App**,且从国内服务器拉很快。
3. `version` 变了就重新拉配置/离线包(类似现在主文档的版本校验)。

> 动态接口(跨境实时数据)仍由你的**后端镜像**解决,与本配置服务可以是同一台服务器。

## 数据/存储

- 配置存 `server/data/config.json`(纯文件,改完即生效,无需数据库)。
- 离线包存 `server/bundles/<id>/`,通过 `/bundles` 静态托管。
- 生产部署:`server` 用 pm2/systemd 常驻;`web` 跑 `npm run build` 出静态文件,用 nginx 托管并反代 `/api`、`/bundles` 到 server。

## 更新日志

### 2026-06-05 —— 后台升级为正式管理系统

- **登录鉴权**:从「单一 token」改为**账号 + 密码**登录。密码用 scrypt 加盐哈希存 `data/users.json`(不存明文);登录后颁发会话 token 存 `data/sessions.json`,有效期 7 天,服务重启不掉线。
- **修改密码**:新增 `POST /api/admin/password`,登录后在后台右上角用户菜单即可改。
- **默认账号**:`admin` / `admin123`(可用环境变量 `ADMIN_USER` / `ADMIN_PASS` 改);原 `ADMIN_TOKEN` 降级为可选的「脚本主令牌」,默认不开启。
- **界面美化**:全新分栏登录页;新增「概览」仪表盘(统计卡 + 应用速览 + 系统信息);侧边栏改深色带图标、当前项渐变高亮;顶栏加配置版本标签与用户头像下拉(改密 / 退出);统一品牌主色与卡片样式。
