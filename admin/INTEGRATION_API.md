# 测试环境对外集成 API

此 API 用于外部系统向 `harm-youhua` 提交应用信息、应用配置 JSON、适用地区和离线资源。当前版本在服务端硬编码为 **仅允许 `test` 环境**，不能写入 `pre` 或 `prod`。

## 启用和鉴权

在测试环境的 `.env` 中配置独立随机令牌：

```dotenv
INTEGRATION_API_TOKEN=<至少 32 位的随机令牌>
```

未配置令牌时，全部集成接口返回 `503 integration_api_disabled`。不要把真实令牌提交到 Git。

基础路径：`/api/integration/v1`

每次请求必须携带：

```http
Content-Type: application/json
X-Integration-Token: <token>
X-Integration-Client: <调用方名称>
```

也可使用 `Authorization: Bearer <token>`。所有写请求还必须提供 8–128 位幂等键：

```http
X-Idempotency-Key: <调用方生成的唯一键>
```

同一个幂等键、路径和请求体重复提交时会返回首次结果，并带响应头 `X-Idempotent-Replay: true`；同一个键用于不同请求时返回 `409 idempotency_conflict`。

## 推荐调用顺序

1. 创建或更新测试应用。
2. 设置应用地区。
3. 上传应用配置 JSON。
4. 上传离线资源，或让服务端从 URL 拉取资源。
5. 查询应用状态并通过 `/test/api/config`、`/test/bundles/<appId>/manifest.json` 验证。

所有请求体都必须显式传入 `"environment": "test"`。查询接口通过 `?environment=test` 指定。

## 1. 创建或更新应用

`PUT /api/integration/v1/apps/:id`

```json
{
  "environment": "test",
  "app": {
    "name": "外部测试应用",
    "url": "https://example.test/app",
    "scope": "region",
    "regions": [
      { "id": "test-region-1", "name": "测试地区一" }
    ],
    "routes": ["/app", "/detail"],
    "appId": "external-app-id",
    "appVersion": "1.0.0",
    "bundle": true
  }
}
```

`:id` 只能包含英文字母、数字、下划线和短横线。新应用的离线包环境固定为 `test`。若同名应用已经关联预发或生产配置/离线文件，接口返回 `409 protected_environment_state`，不会修改共享应用字段。

## 2. 设置地区

`PUT /api/integration/v1/apps/:id/regions`

```json
{
  "environment": "test",
  "regions": [
    { "id": "test-region-1", "name": "测试地区一" },
    { "id": "test-region-2", "name": "测试地区二" }
  ]
}
```

此接口为全量替换，至少需要一个地区。为避免修改共享字段，已经关联 `pre/prod` 的应用会被拒绝。

## 3. 上传配置 JSON

`PUT /api/integration/v1/apps/:id/config-json`

```json
{
  "environment": "test",
  "fileName": "external-app-test.json",
  "configJson": {
    "url": "https://example.test/app",
    "title": "测试应用配置",
    "version": 1
  }
}
```

`configJson` 可以是 JSON 对象，也可以是合法的 JSON 字符串，最大 8 MB；其中 `url` 必须与应用 URL 同源。该接口只替换目标应用的 `test` 配置分区，原有 `pre/prod` 分区按原始内容保留。

## 4. 上传离线资源内容

`POST /api/integration/v1/apps/:id/resources/upload`

```json
{
  "environment": "test",
  "maxResourceKB": 4096,
  "resources": [
    {
      "url": "https://example.test/assets/app.12345678.js",
      "mime": "application/javascript",
      "contentBase64": "Y29uc29sZS5sb2coJ3Rlc3QnKTs=",
      "sha256": "df1f03136efd86bf28fc0ab4744747e160292309f9adb44a86e80fce7e81a1fc"
    }
  ]
}
```

一次最多 100 个资源，单文件默认不超过 4 MB、可通过 `maxResourceKB` 调整但最高 8 MB，单次请求解码后的总内容不超过 12 MB。全部资源校验通过后写入 `test` 离线包并重新生成普通及压缩 manifest。若提供 `sha256`，内容哈希必须一致。

## 5. 从 URL 导入离线资源

`POST /api/integration/v1/apps/:id/resources/import-urls`

```json
{
  "environment": "test",
  "maxResourceKB": 4096,
  "resources": [
    {
      "url": "https://example.test/assets/app.12345678.js",
      "size": 123456,
      "costMs": 320,
      "source": "device-report"
    }
  ]
}
```

服务端下载成功的资源会写入 `test` 离线包并重建 manifest。该应用若已关联 `pre/prod` 会被拒绝。

## 6. 查询应用状态

`GET /api/integration/v1/apps/:id?environment=test`

响应包含测试配置、地区、测试离线包状态和 manifest 资源数量。发布验证入口：

```text
GET /test/api/config
GET /test/bundles/<appId>/manifest.json
GET /test/bundles/<appId>/manifest.zz.json
```

## 环境保护和审计

- 缺少环境参数返回 `400 environment_required`。
- 传入 `pre`、`prod` 或任何非 `test` 值返回 `403 test_environment_only`。
- 集成接口不会创建或写入 `bundles/pre`、`bundles/prod`。
- 每次已鉴权请求会记录到运行数据目录的 `integration-audit.jsonl`，仅记录请求 ID、调用方、令牌指纹、动作、应用 ID、环境、状态码和耗时，不记录令牌及请求正文。
- 幂等结果保存在运行数据目录的 `integration-idempotency.json`。这两个文件属于运行数据，不应提交到 Git。

## curl 示例

```bash
curl -X PUT "https://<测试后台域名>/api/integration/v1/apps/external_demo" \
  -H "Content-Type: application/json" \
  -H "X-Integration-Token: $INTEGRATION_API_TOKEN" \
  -H "X-Integration-Client: partner-a" \
  -H "X-Idempotency-Key: partner-a-create-0001" \
  --data '{"environment":"test","app":{"name":"External Demo","url":"https://example.test/app","scope":"region","regions":[{"id":"test-region-1","name":"测试地区一"}],"bundle":true}}'
```
