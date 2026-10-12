# harm-youhua

鸿蒙网页应用离线加速项目，由端侧 SDK/元服务和远程配置后台组成。

```text
harm-youhua/
├── app/
│   ├── webaccel/   HAR SDK：拉取配置、下载离线资源、WebView 本地命中
│   └── entry/      HarmonyOS 元服务壳
└── admin/
    ├── server/     Node.js：配置 API、三环境集成 API、离线资源托管
    └── web/        Vue 3 管理界面
```

## 当前实现边界

- 端侧只保留“远程配置 + 后台离线包 + WebView 本地命中”链路。
- 不做运行时静态资源自动缓存、主文档 SWR、离屏预渲染或 chunk 预取。
- 离线资源不打进 HAP/HAR，由后台托管并下载到接入方应用沙箱。
- 黑名单仍沿用现有全局机制。本轮不修改 HAR，也不新增应用级黑名单。
- 外部系统可通过集成 API 创建应用、设置地区、上传配置 JSON 和离线资源。
- 集成 API 通过独立路径和令牌开放 `test`、`pre`、`prod`，地区、JSON 和离线资源按环境隔离。
- 后台主要用于查看接口托管结果，以及控制是否向对应环境设备下发离线资源。

给调用方的完整接口说明见 [对外接口交互文档.md](对外接口交互文档.md)。

## 本地运行

### 后台服务

```powershell
cd admin/server
npm install
$env:ADMIN_USER='<admin-name>'
$env:ADMIN_PASS='<strong-password>'
$env:INTEGRATION_API_TOKEN_TEST='<test-token>'
$env:INTEGRATION_API_TOKEN_PRE='<pre-token>'
$env:INTEGRATION_API_TOKEN_PROD='<prod-token>'
npm start
```

默认监听 `http://localhost:8787`。首次启动使用环境变量创建后台账号，密码只以哈希形式写入运行数据。

本机演示页面时可以临时设置 `$env:LOCAL_DEMO_NO_AUTH='1'`，此时只有环回地址可免登录；远程请求仍需正常鉴权。测试服务器、预发和生产不得开启该变量。

### 管理界面

```powershell
cd admin/web
npm install
npm run dev
```

开发服务器默认由 Vite 提供，API 代理到后台服务。后端也可同源托管 `admin/web/dist`。

### 自动测试与构建

```powershell
cd admin/server
npm test

cd ../web
npm run build
```

集成 API 的鉴权、幂等、环境隔离、JSON 和离线资源上传由 `admin/server/test/integration-api.test.js` 覆盖。

## HarmonyOS 构建

用 DevEco Studio 打开 `app/` 并完成 Sync。命令行示例：

```powershell
cd app
hvigorw assembleHar -p module=webaccel@default
hvigorw --mode module -p module=entry@default -p product=default assembleHap
```

首次构建需要配置元服务签名。不要把本机签名路径、口令或临时 bundleName 提交到 Git。

## 文档入口

- [admin/README.md](admin/README.md)：后台能力、本地运行和数据目录。
- [对外接口交互文档.md](对外接口交互文档.md)：可直接交给调用方的完整接口说明。
- [app/webaccel/README.md](app/webaccel/README.md)：HAR SDK 接入。
- [app/UPDATE.md](app/UPDATE.md)：更新与发版边界。
- [SDK_OFFLINE_BUNDLE.md](SDK_OFFLINE_BUNDLE.md)：离线包机制。
- [OFFLINE_BUNDLE_ARCHITECTURE.md](OFFLINE_BUNDLE_ARCHITECTURE.md)：端、云、沙箱关系。
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md)：仍有参考价值的排障记录。
- [DEPLOY.md](DEPLOY.md)：部署说明；没有明确授权时只做本地验证，不执行远端部署。

## 工作约束

1. 先在本地完成接口测试和页面验证。
2. 用户确认后再提交或推送 Git。
3. 部署前备份服务器运行配置和三个环境离线资源；接口写入严格按环境隔离。
4. 本轮接口化不改 HAR，也不改 AtomicPlatform；相关能力需等双方版本协同后再迭代。
