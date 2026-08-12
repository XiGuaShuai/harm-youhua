# WEBACCEL 缓存分析

结论来自 `app/webaccel/src/main/ets/core/WebCacheManager.ets` 和 `app/webaccel/README.md`。

## 目录

- 根目录: `context.filesDir/webcache`
- 索引: `context.filesDir/webcache/index.json`
- 状态: `context.filesDir/webcache/bundle-state.json`
- 资源文件: `context.filesDir/webcache/<hash>.bin`

## 命名

- `fileNameFor(url)` 对归一化后的 URL 做双 hash
- 输出固定为 `16` 位十六进制加 `.bin`
- 不是按 `appId`、`bundleId` 或原始 URL 明文命名

## 沙箱关系

- 缓存落在当前应用自己的 `filesDir`
- 默认和应用沙箱一一对应
- 不同应用不会共享同一份离线包缓存目录

## 删除规则

- `deleteRegion(region)` 只删 `scope=region`
- `deleteBundle(id)` 只删指定 id 对应的离线包
- `index.json` 和 `bundle-state.json` 会同步更新
