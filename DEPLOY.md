# 部署:本地改完 → `git push` → 服务器自动更新

后台(`admin/`)用 **Docker + git push 自动部署**,跑在服务器 `47.236.73.89`(`meta-proxy1`)上,
由该机**已有的 nginx** 反代,对外用域名 **`maidun.chujingservice.com`**。

一次性配好后,日常更新只需在本地:

```bash
git add -A && git commit -m "..."   # 提交改动
git push server main                # 推送即自动部署
```

服务器收到推送后自动 `docker compose up -d --build`:**重建镜像(代码更新)、保留数据卷(账号配置 / 离线包不丢)**。

---

## 架构

```
公网 → nginx(宿主机已有, 监听 80) ──反代──> 127.0.0.1:8787 ── 后台容器 youhua-admin
        server_name maidun.chujingservice.com            (Node 后端 + 已构建的 Vue 管理界面)

卷 youhua_admin-data     = data/(账号 / 会话 / config.json)   ┐ 换镜像(更新代码)时
卷 youhua_admin-bundles  = bundles/(cache-builder 产出的离线包) ┘ 原封不动
```

- 容器**只绑 `127.0.0.1:8787`**,不暴露公网;统一从 nginx 进,走已开放的 80 端口,**无需改阿里云安全组**。
- 与该机现有的 `sub2api`(8080)等容器**互不影响**(独立 compose 项目、独立卷)。

对外地址(配好 nginx 后):
- 管理界面:`http://maidun.chujingservice.com/`
- 鸿蒙 App 配置接口:`http://maidun.chujingservice.com/api/config`
- 离线包:`http://maidun.chujingservice.com/bundles/<id>/manifest.json`

> 鸿蒙 **debug** 包把 `app/webaccel/build-profile.json5` 的 `CONFIG_SERVER` 改成 `http://maidun.chujingservice.com`。
> **release** 包要求 HTTPS,见文末「升级到 HTTPS」(在 maidun 这个站上跑一次 certbot 即可)。

---

## 一次性配置(四步)

### ① 本地 → 服务器免密(SSH 密钥)

本地 **PowerShell**(`-N '""'` = 无口令,便于自动部署):

```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\youhua -N '""'
type $env:USERPROFILE\.ssh\youhua.pub | ssh yuan@47.236.73.89 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
Add-Content $env:USERPROFILE\.ssh\config "`nHost 47.236.73.89`n  User yuan`n  IdentityFile ~/.ssh/youhua"
```

验证:`ssh yuan@47.236.73.89 "echo ok"` 不再要密码即成功。
**配好后请登录服务器把原始登录密码改掉(它已在聊天里暴露)。**

### ② 服务器一键引导(建裸仓库 + 部署钩子;Docker 已装会自动跳过)

```powershell
cd D:\youhua-mono
scp deploy/bootstrap-server.sh yuan@47.236.73.89:/tmp/
ssh yuan@47.236.73.89 "sudo bash /tmp/bootstrap-server.sh yuan"
```

脚本结束会打印**随机生成的后台密码**,记下来。

### ③ 本地加远程并首次推送(推完容器就跑在 127.0.0.1:8787)

```powershell
cd D:\youhua-mono
git remote add server ssh://yuan@47.236.73.89/srv/youhua.git
git add -A
git commit -m "新增 Docker 部署:后端同源托管前端 + git push 自动部署"
git push server main
```

推送日志出现 `✓ 部署完成` 即容器已起。验证(在服务器上):`curl -s http://127.0.0.1:8787/api/config | head -c 100`

### ④ 装 nginx 反代(把 maidun 指向后台;先备份、校验,再生效)

在**服务器**上执行:

```bash
# 备份原 maidun 配置
sudo cp /etc/nginx/conf.d/maidun.chujingservice.com.conf /etc/nginx/conf.d/maidun.chujingservice.com.conf.bak.$(date +%s)
# 用仓库里的新配置覆盖
sudo cp /srv/youhua/deploy/nginx-maidun.conf /etc/nginx/conf.d/maidun.chujingservice.com.conf
# 校验通过才 reload(校验失败就别 reload,改回 .bak)
sudo nginx -t && sudo systemctl reload nginx
```

浏览器打开 `http://maidun.chujingservice.com/` 即后台。万一 `nginx -t` 报错:
`sudo cp /etc/nginx/conf.d/maidun.chujingservice.com.conf.bak.* /etc/nginx/conf.d/maidun.chujingservice.com.conf` 还原即可。

---

## 日常操作

| 目的 | 命令 |
|---|---|
| 发布更新 | 本地 `git push server main` |
| 看运行日志 | 服务器 `cd /srv/youhua && docker compose logs -f` |
| 重启 | 服务器 `cd /srv/youhua && docker compose restart` |
| 停止(不丢数据) | 服务器 `docker compose down` |
| 改后台密码 | 后台界面「修改密码」,或改 `/srv/youhua/.env` 的 `ADMIN_PASS` 后 `docker compose up -d` |
| 备份数据 | 服务器 `docker run --rm -v youhua_admin-data:/d -v youhua_admin-bundles:/b -v $PWD:/out alpine tar czf /out/youhua-backup.tgz /d /b` |

**回滚到上一版**:本地 `git push server <旧 commit>:main`,或服务器 `git --git-dir=/srv/youhua.git --work-tree=/srv/youhua checkout -f <commit> && cd /srv/youhua && docker compose up -d --build`。

---

## 升级到 HTTPS(鸿蒙 release 需要)

maidun 的 DNS 已指向本机,直接在这个站上签证书即可:

```bash
sudo certbot --nginx -d maidun.chujingservice.com     # 没有 certbot 先装:sudo dnf install -y certbot python3-certbot-nginx
```

certbot 会自动给 `maidun.chujingservice.com.conf` 加 443/证书并配置自动续期。
之后鸿蒙 release 包的 `CONFIG_SERVER` 改成 `https://maidun.chujingservice.com`。
