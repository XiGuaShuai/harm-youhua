# 后台镜像 —— 多阶段构建
#   阶段 web    : 构建 Vue 管理界面(admin/web → dist)
#   阶段 server : Node 运行 Express 后端,并同源托管上一步的 dist
# 构建上下文为 admin/(见 docker-compose.yml 的 build.context)

# ---------- 阶段 1:构建管理界面 ----------
FROM node:20-slim AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build                     # 产出 /web/dist

# ---------- 阶段 2:运行后端 ----------
FROM node:20-slim AS server
ENV NODE_ENV=production
WORKDIR /app/server
COPY server/package.json server/package-lock.json ./
RUN npm ci --omit=dev
COPY server/ ./
# 前端构建产物放到后端能托管的位置(与 index.js 里 WEB_DIST 默认值一致)
COPY --from=web /web/dist /app/web/dist
ENV WEB_DIST=/app/web/dist
ENV PORT=8787
EXPOSE 8787
CMD ["node", "index.js"]
