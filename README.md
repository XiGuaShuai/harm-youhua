# youhua-mono

「网页应用集合」鸿蒙加速方案的单仓库(monorepo),由两部分组成:

```
youhua-mono/
├── app/                鸿蒙元服务(Atomic Service)工程 —— 多层加速(离线缓存 / 离屏预渲染 / chunk 预取 / 远程配置)
│   ├── webaccel/       加速能力封装成的 HAR SDK(被 entry 依赖,也可被别的工程复用)
│   └── entry/          元服务本体(installationFree,消费 webaccel)
└── admin/              配套后台 —— server(Node+Express 配置 API + 离线包托管)+ web(Vue3 + Vite + Element Plus + Pinia 管理界面)
```

> 原 `D:\youhua` → `app/`,原 `D:\youhua-suite\admin` → `admin/`。

## 两者关系

- **app** 是端侧元服务:加速能力抽成 `webaccel` HAR SDK,`entry` 是消费它的**元服务本体**(`bundleType: atomicService` + `installationFree: true`);**开机从服务器拉配置**(应用 / 黑名单 / 设置),打开网页应用时**按需下载离线包**进沙箱,带自愈式缓存。
- **admin** 是后台:让端侧 **开机从服务器拉配置** 和 **离线包**,改东西不用重新发版。

SDK API 与元服务注意事项见 `app/webaccel/README.md`;后台接入见 `admin/README.md`;更新/发版流程见 `app/UPDATE.md`。

## 快速开始

### app(鸿蒙元服务)
用 DevEco Studio 打开 `app/` 并 **Sync**(解析 `entry → webaccel` 本地依赖),命令行构建:

```bash
cd app
# 单独产出 SDK(HAR,供别的工程复用;entry 构建时会自动并入,无需手动先跑)
hvigorw assembleHar -p module=webaccel@default
# 构建元服务 HAP
hvigorw --mode module -p module=entry@default -p product=default assembleHap
```

> **首次需在 DevEco 配置元服务签名**:`File > Project Structure > Signing Configs` 勾选自动签名(需登录已开通元服务的华为账号)——原普通 App 的证书无法用于元服务。
> 「不要打 rawfile 离线包、保持包体 ≤ 2MB」等见 `app/webaccel/README.md`。

### admin(后台)

```bash
# 后端(端口 8787)
cd admin/server && npm install && npm start

# 管理界面(端口 5174,开发时代理到 8787)
cd admin/web && npm install && npm run dev
```

## SDK 离线包说明

SDK 作为接入方能力时,离线包会由接入方 App 端侧自动下载并存入接入方自己的沙箱。多站点 `bundle:true` 会逐站预下载,用于页面秒开。详细边界、压缩策略、K11 实测体积和后台配置要求见 [SDK_OFFLINE_BUNDLE.md](SDK_OFFLINE_BUNDLE.md)。
