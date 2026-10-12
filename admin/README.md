# youhua-admin

远程配置和离线资源服务。`server/` 提供 Node.js API 与静态资源托管，`web/` 提供 Vue 3 管理界面。

## 当前三环境接口模式

测试应用由外部系统通过接口维护：

1. 创建或更新应用。
2. 设置适用地区。
3. 上传配置 JSON。
4. 上传完整离线资源快照；只上报变化文件时也可增量上传或提交 URL 让服务端拉取。
5. 查询状态并验证目标环境配置和 manifest。

服务端通过环境前缀路径和独立令牌开放 `test`、`pre`、`prod`。地区、配置 JSON、资源元数据、发布版本和物理离线包均按环境隔离；应用共享身份字段冲突会被拒绝。接口细节见 [../对外接口交互文档.md](../对外接口交互文档.md)。

测试后台的职责是查看接口提交结果，并控制离线资源“下发/暂停”：

- `/test#/`：测试应用、离线包和资源概览。
- `/test#/apps`：应用、地区、JSON、离线资源状态和下发开关。
- `/test#/config-json`：只读查看已上传的 JSON。
- `/test#/bundles`：查看已有离线资源。
- `/test#/blocklist`：保留原有全局黑名单页面，本轮不改动其机制。

测试环境不显示“全局设置”。设置数据和非测试环境原有页面没有被删除。

## 本地运行

需要 Node.js 18 或更高版本。

```powershell
cd server
npm install
$env:ADMIN_USER='<admin-name>'
$env:ADMIN_PASS='<strong-password>'
$env:INTEGRATION_API_TOKEN_TEST='<test-token>'
$env:INTEGRATION_API_TOKEN_PRE='<pre-token>'
$env:INTEGRATION_API_TOKEN_PROD='<prod-token>'
npm start
```

默认地址为 `http://localhost:8787`。首次启动必须提供管理员账号和密码；后续从 `DATA_DIR` 中的用户数据读取。

另开终端启动前端开发服务：

```powershell
cd web
npm install
npm run dev
```

构建后的 `web/dist` 可由后台同源托管。

## 本地隔离验证

不要让本地调试读写现有服务器数据。使用独立目录和端口：

```powershell
$env:DATA_DIR='<temporary-data-directory>'
$env:BUNDLES_DIR='<temporary-bundles-directory>'
$env:WEB_DIST='<absolute-path-to-admin-web-dist>'
$env:PORT='8787'
$env:ADMIN_USER='local-preview'
$env:ADMIN_PASS='<local-only-password>'
$env:INTEGRATION_API_TOKEN_TEST='<local-test-token>'
$env:INTEGRATION_API_TOKEN_PRE='<local-pre-token>'
$env:INTEGRATION_API_TOKEN_PROD='<local-prod-token>'
node index.js
```

完成验证后只删除本次创建的临时目录，不要清理共享或服务器数据目录。

## 测试与构建

```powershell
cd server
npm test

cd ../web
npm run build
```

`integration-api.test.js` 会使用临时数据和资源目录启动独立服务，覆盖以下行为：

- 未鉴权请求被拒绝。
- 三个环境的路径、令牌、地区、JSON、离线资源和版本信息互相隔离。
- 幂等键可安全重放并检测冲突。
- 应用、地区和配置 JSON 写入。
- 离线资源上传和 manifest 生成。
- 完整资源快照的原子替换、版本冲突保护和失败保留旧包。
- 网页设置的暂停下发状态在资源更新后仍保留。
- 审计文件不记录令牌和请求正文。

## 关键接口

| 接口 | 用途 |
|---|---|
| `GET /test/api/config` | 测试设备拉取配置 |
| `GET /test/bundles/<id>/manifest.json` | 测试环境离线资源清单 |
| `GET /api/integration/v1/:environment/apps/:id` | 查询指定环境应用状态 |
| `PUT /api/integration/v1/:environment/apps/:id` | 创建或配置指定环境应用 |
| `PUT /api/integration/v1/:environment/apps/:id/regions` | 全量设置指定环境地区 |
| `PUT /api/integration/v1/:environment/apps/:id/config-json` | 上传指定环境配置 JSON |
| `PUT /api/integration/v1/:environment/apps/:id/resources/snapshot` | 原子替换指定环境完整离线包 |
| `POST /api/integration/v1/:environment/apps/:id/resources/upload` | 增量上传指定环境资源 |
| `POST /api/integration/v1/:environment/apps/:id/resources/import-urls` | 从 URL 导入指定环境资源 |
| `POST /api/login` | 后台账号登录 |
| `/api/admin/*` | 原有后台管理接口，需要后台会话令牌 |

无环境前缀的 `/api/config` 和 `/bundles/*` 为旧客户端兼容路径，按生产环境处理，不能用来验证测试数据。

## 数据目录

- `DATA_DIR/config.json`：应用、地区、环境配置、黑名单和设置。
- `DATA_DIR/users.json`：管理员账号的加盐哈希。
- `DATA_DIR/sessions.json`：后台会话。
- `DATA_DIR/integration-audit.jsonl`：集成接口审计，不记录请求正文和原始令牌。
- `DATA_DIR/integration-idempotency.json`：幂等结果。
- `BUNDLES_DIR/{test,pre,prod}/<appId>/`：各环境离线资源和 manifest。

这些都是运行数据，不应提交到 Git。

## 发布约束

- 先完成本地测试和页面检查。
- 用户确认后才能提交或推送 Git。
- 没有明确授权时，不部署，也不修改预发或生产环境。
- 本轮不修改 `app/webaccel` HAR 和 AtomicPlatform。
