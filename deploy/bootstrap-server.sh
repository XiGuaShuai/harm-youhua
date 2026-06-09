#!/usr/bin/env bash
# 在服务器上「以 root」运行一次,完成:装 Docker → 建裸仓库 → 装 post-receive 部署钩子。
# 之后本地每次 `git push server main` 都会自动 docker compose 重建重启。
#
#   用法:  sudo bash bootstrap-server.sh [部署用户=yuan]
set -euo pipefail

DEPLOY_USER="${1:-yuan}"
GIT=/srv/youhua.git
WORK=/srv/youhua

echo "==> [1/5] 安装 Docker(已装则跳过)"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

echo "==> [2/5] 允许 $DEPLOY_USER 直接用 docker(部署钩子以该用户身份运行)"
usermod -aG docker "$DEPLOY_USER"

echo "==> [3/5] 建裸仓库 $GIT 与工作目录 $WORK"
mkdir -p "$GIT" "$WORK"
git init --bare "$GIT" >/dev/null

echo "==> [4/5] 安装 post-receive 钩子"
cat > "$GIT/hooks/post-receive" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
WORK=/srv/youhua
GIT=/srv/youhua.git
mkdir -p "$WORK"
while read -r oldrev newrev ref; do
  branch="${ref#refs/heads/}"
  { [ "$branch" = "main" ] || [ "$branch" = "master" ]; } || continue
  echo "==> 检出 $branch 到 $WORK"
  git --work-tree="$WORK" --git-dir="$GIT" checkout -f "$branch"
  cd "$WORK"
  if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi
  echo "==> $DC 重建并重启"
  $DC up -d --build
  docker image prune -f >/dev/null 2>&1 || true
  echo "✓ 部署完成 → 容器已在 127.0.0.1:8787;由 nginx 反代 maidun.chujingservice.com"
done
HOOK
chmod +x "$GIT/hooks/post-receive"

echo "==> [5/5] 准备 .env(随机生成后台密码;不存在时才写)"
if [ ! -f "$WORK/.env" ]; then
  PASS="$(openssl rand -base64 12 2>/dev/null || head -c 12 /dev/urandom | base64)"
  printf 'ADMIN_USER=admin\nADMIN_PASS=%s\n' "$PASS" > "$WORK/.env"
  echo "   已生成后台账号:  admin / $PASS   (登录后可在后台修改密码)"
fi

chown -R "$DEPLOY_USER:$DEPLOY_USER" "$GIT" "$WORK"

echo
echo "✓ 服务器就绪。请到本地仓库执行:"
echo "    git remote add server ssh://$DEPLOY_USER@47.236.73.89/srv/youhua.git"
echo "    git push server main"
echo
echo "推送后容器会跑在 127.0.0.1:8787;再装好 nginx 配置(deploy/nginx-maidun.conf)即可经 maidun.chujingservice.com 访问。"
echo "走现有 nginx 的 80/443,无需改阿里云安全组。"
