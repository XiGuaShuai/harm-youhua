# youhua-mono

「网页应用集合」鸿蒙加速方案的单仓库(monorepo),由两部分组成:

```
youhua-mono/
├── app/      鸿蒙(HarmonyOS)App「网页应用集合」—— 多层加速(离线缓存 / 内置包 / 字节码 / 离屏预渲染)
└── admin/    配套后台 —— server(Node+Express 配置 API + 离线包托管)+ web(Vue3 + Vite + Element Plus + Pinia 管理界面)
```

> 原 `D:\youhua` → `app/`,原 `D:\youhua-suite\admin` → `admin/`。

## 两者关系

- **app** 是端侧:把网页应用列表、过滤黑名单、离线包打进 HAP,并带自愈式缓存。
- **admin** 是后台:让 App **开机从服务器拉配置**(应用 / 黑名单 / 设置)和**离线包**,改东西不用重新发版。

接入细节见 `admin/README.md` 第「鸿蒙 App 端怎么接」一节;App 更新/发版流程见 `app/UPDATE.md`。

## 快速开始

### app(鸿蒙)
用 DevEco Studio 打开 `app/`,或命令行:

```bash
cd app
bash tools/refresh-offline-bundle.sh          # 刷新内置包
hvigorw --mode module -p module=entry@default -p product=default assembleHap
```

### admin(后台)

```bash
# 后端(端口 8787)
cd admin/server && npm install && npm start

# 管理界面(端口 5174,开发时代理到 8787)
cd admin/web && npm install && npm run dev
```
