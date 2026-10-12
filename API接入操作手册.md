# harm-youhua API 接入操作手册

这份文件给实际调用接口的开发人员使用。完整字段、响应和错误码见 [对外接口交互文档.md](./对外接口交互文档.md)。

## 1. 先选择环境

三个环境的数据、令牌、JSON 和离线资源互相隔离。调用哪个环境，就使用对应的 Base URL 和对应令牌。

| 环境 | Base URL |
| --- | --- |
| 测试 | `https://maidun.chujingservice.com/api/integration/v1/test` |
| 预发 | `https://maidun.chujingservice.com/api/integration/v1/pre` |
| 生产 | `https://maidun.chujingservice.com/api/integration/v1/prod` |

令牌由服务器负责人分别发放，不要写进代码仓库、接口文档或日志。下面以测试环境为例：

```bash
export BASE_URL="https://maidun.chujingservice.com/api/integration/v1/test"
export API_TOKEN="负责人单独提供的测试令牌"
export CLIENT_NAME="your-team-name"
```

每个请求固定携带：

```http
X-Integration-Token: <当前环境令牌>
X-Integration-Client: <调用方名称>
Content-Type: application/json
```

所有写请求还要携带一个新的幂等键：

```http
X-Idempotency-Key: <本次操作唯一值，8-128 位>
```

## 2. 创建或更新应用

```bash
curl -X PUT "$BASE_URL/apps/beacukai" \
  -H "Content-Type: application/json" \
  -H "X-Integration-Token: $API_TOKEN" \
  -H "X-Integration-Client: $CLIENT_NAME" \
  -H "X-Idempotency-Key: beacukai-app-20261012-0001" \
  --data '{
    "app": {
      "name": "印尼电子入境卡",
      "url": "https://ecd.beacukai.go.id/",
      "scope": "region",
      "userAgent": "该应用在真机中实际使用的 UA",
      "routes": ["/"],
      "bundle": true
    }
  }'
```

同一个 `appId` 在三个环境共用名称、URL、UA 等基础字段，三个环境提交时这些字段必须一致。

## 3. 设置该应用的全部地区

这是全量替换，不是追加。每次都提交该应用在当前环境使用的完整地区数组。

```bash
curl -X PUT "$BASE_URL/apps/beacukai/regions" \
  -H "Content-Type: application/json" \
  -H "X-Integration-Token: $API_TOKEN" \
  -H "X-Integration-Client: $CLIENT_NAME" \
  -H "X-Idempotency-Key: beacukai-regions-20261012-0001" \
  --data '{
    "regions": [
      {"id": "1999320112476409857", "name": "印度尼西亚"},
      {"id": "test-region-2", "name": "第二个测试地区"}
    ]
  }'
```

一个应用只保存一份当前环境 JSON。更新 JSON 后，该应用在当前环境的所有地区都会使用新 JSON，不需要逐地区重复更新。

## 4. 更新应用 JSON

如果调用方已经拿到最终 JSON，直接提交：

```bash
curl -X PUT "$BASE_URL/apps/beacukai/config-json" \
  -H "Content-Type: application/json" \
  -H "X-Integration-Token: $API_TOKEN" \
  -H "X-Integration-Client: $CLIENT_NAME" \
  -H "X-Idempotency-Key: beacukai-json-20261012-0001" \
  --data '{
    "fileName": "IndonesianEntryCard.json",
    "configJson": {
      "title": "印尼电子入境卡",
      "url": "https://ecd.beacukai.go.id/"
    }
  }'
```

如果需要服务器登录第三方接口后自动拉取 JSON，先调用 `PUT /apps/:appId/config-json-sync` 保存登录和读取规则，再调用 `POST /apps/:appId/config-json-sync/run` 立即同步。具体字段见完整文档第 6 节。

## 5. 上传完整离线资源

自动监控和日常发布统一使用完整快照接口。`resources` 必须是这次版本的全部资源；成功后，没有出现在数组里的旧资源会被删除。

先查询服务器当前版本：

```bash
curl "$BASE_URL/apps/beacukai" \
  -H "X-Integration-Token: $API_TOKEN" \
  -H "X-Integration-Client: $CLIENT_NAME"
```

记录响应中的 `app.resourceRelease.releaseId`。首次发布或服务器没有版本时使用空字符串，然后上传快照：

```bash
curl -X PUT "$BASE_URL/apps/beacukai/resources/snapshot" \
  -H "Content-Type: application/json" \
  -H "X-Integration-Token: $API_TOKEN" \
  -H "X-Integration-Client: $CLIENT_NAME" \
  -H "X-Idempotency-Key: beacukai-snapshot-20261012-0001" \
  --data @snapshot.json
```

`snapshot.json` 示例：

```json
{
  "releaseId": "beacukai-test-20261012-0001",
  "expectedReleaseId": "",
  "resources": [
    {
      "url": "https://ecd.beacukai.go.id/assets/app.js",
      "contentBase64": "LyogZmlsZSBjb250ZW50ICov",
      "sha256": "文件原始字节的 64 位小写 SHA-256",
      "mime": "application/javascript"
    }
  ]
}
```

限制：`resources` 至少包含 1 个资源，单次最多 200 个资源，解码后总大小最多 10 MB；同一个 `releaseId` 不能对应不同内容。该接口用于发布完整快照，不接受空数组。需要清空测试包做联调时，由服务器负责人执行受控重置；调用方不要用空快照、删除应用或操作预发/生产来模拟清空。

## 6. 验证操作结果

再次调用：

```bash
curl "$BASE_URL/apps/beacukai" \
  -H "X-Integration-Token: $API_TOKEN" \
  -H "X-Integration-Client: $CLIENT_NAME"
```

至少核对：

- `environment` 是本次目标环境；
- `regions` 是完整地区数组；
- `configJsonSyncedAt` 已更新；
- `resourceRelease.releaseId` 是本次版本；
- `resourceRelease.resourceCount` 与上传资源数一致；
- `offlineBundle.count` 与实际 manifest 资源数一致。

测试环境资源清单还可直接查看：

```text
https://maidun.chujingservice.com/test/bundles/beacukai/manifest.json
```

预发和生产分别把路径中的 `test` 换成 `pre`、`prod`。

## 7. 自动监控程序怎么调用

每轮执行下面的固定流程：

1. 用该应用自己的 UA 扫描入口页并捕获静态资源；
2. 对每个文件计算 SHA-256，并生成整包摘要；
3. 调用 `GET /apps/:appId` 查询目标环境实际版本；
4. 源站有变化、服务器没有 `resourceRelease`、摘要不一致或资源数量不一致时，生成新的 `releaseId`；
5. 调用 `PUT /apps/:appId/resources/snapshot` 上传完整快照；
6. 再查询一次并核对发布结果；
7. 自动化默认只发布测试环境，预发和生产必须经过真机验证和人工确认。

即使源站扫描结果与上次相同，只要服务器缺包，也必须重新上传，不能直接显示“无变化”。

每个应用必须配置自己的真实 UA。监控程序根据 `appId` 读取该应用的 `userAgent`、入口 URL、允许域名和过滤规则，不能把一个应用的 UA 复用于其他应用。

暂停应用只会停止定时扫描，不会禁止人工操作。联调时应先暂停应用，再由操作人员在监控后台点击“扫描并同步”；该操作只修复测试环境，不能自动写入预发或生产。

## 8. 交付前检查

- 测试、预发、生产使用了各自的 Base URL 和令牌；
- 应用 ID、URL、UA 在三个环境保持一致；
- 地区接口提交的是完整数组；
- JSON 的 `url` 与应用 URL 同源；
- 每个写请求使用新的幂等键；
- 上传前传入刚查询到的 `expectedReleaseId`；
- 日志中没有令牌、密码、Cookie 或资源正文；
- 先在测试环境真机确认下载完成和离线命中，再操作预发或生产。
