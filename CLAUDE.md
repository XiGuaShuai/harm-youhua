# 项目协作导航

本文件只保留当前仍有效的接手信息。项目总览先读 [README.md](README.md)。

## 当前目标

`harm-youhua` 已把三个环境的应用维护流程接口化：调用方通过不同环境路径和令牌提交应用、地区、配置 JSON 和离线资源；后台网页负责展示状态，并控制是否向对应设备下发离线资源。

完整接口见 [对外接口交互文档.md](对外接口交互文档.md)。

## 硬边界

- 集成 API 必须按 `test`、`pre`、`prod` 路径、令牌和数据分区隔离，不能跨环境覆盖。
- 先本地测试，用户确认后才允许提交、推送或部署。
- 部署前备份服务器配置和三个环境资源，部署验证不能创建或修改真实业务应用。
- 不要修改 HAR 或 AtomicPlatform。
- 黑名单维持当前全局实现，不在本轮增加应用级覆盖。
- 不把账号、令牌、签名、服务器私密资料或运行数据提交到仓库。

## 当前后台交互

- `/test#/`：测试环境概览。
- `/test#/apps`：接口托管应用和地区、JSON、离线资源状态；网页只提供下发/暂停控制。
- `/test#/config-json`：查看调用方上传的测试配置 JSON，不在网页里人工维护。
- `/test#/bundles`：已有离线资源管理能力。
- 测试环境隐藏“全局设置”；其现有后端数据结构未删除。

测试环境仍显示原有“过滤黑名单”页面，但当前没有修改它的语义或数据。

## 代码入口

```text
admin/server/index.js                         后台及集成 API
admin/server/test/integration-api.test.js     集成 API 自动测试
admin/web/src/App.vue                         环境导航与页面标题
admin/web/src/views/Dashboard.vue             概览
admin/web/src/views/Apps.vue                  应用管理
admin/web/src/views/ConfigJson.vue            配置 JSON
对外接口交互文档.md                          调用方接口文档
app/webaccel/                                 HAR SDK（本轮不改）
```

## 本地验证

```powershell
cd admin/server
npm test

cd ../web
npm run build
```

需要启动服务时必须使用独立临时 `DATA_DIR` 和本地端口，避免读写现有远端或共享运行数据。

## 文档维护

只保留能说明当前架构、接口、构建、部署、恢复或排障的文档。单次操作日志、旧性能报告、旧会话交接和已取消方案不再放在项目根目录。
