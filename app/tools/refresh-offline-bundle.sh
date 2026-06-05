#!/usr/bin/env bash
# 刷新离线包:抓取首页 + 各路由(二级页面)需要的全部 _next/static 资源
# (JS chunk / CSS / 字体),解压后写入 entry/src/main/resources/rawfile/webcache/,
# 并生成 manifest.json。这样首次启动起,首页和二级页面的 chunk 全在本地,点开即秒显。
# 站点 redeploy(hash 变化)后,发版前重跑一次即可刷新内置包。
set -euo pipefail

BASE="https://ecd.beacukai.go.id"
# 路由列表:/ 是首页;其余是各二级页面。站点新增页面 → 在这里加一行。
ROUTES=("/" "/forms/bc22" "/forms/bc32" "/forms/bc34")

OUT="$(cd "$(dirname "$0")/.." && pwd)/entry/src/main/resources/rawfile/webcache"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
CURL=(curl -s --compressed --max-time 120 --retry 5 --retry-delay 2 --retry-all-errors -A "$UA")
DL=(curl -s -f --compressed --max-time 120 --retry 3 --retry-delay 2 -A "$UA")  # -f:HTTP错误即失败,跳过坏 URL

echo "清空并重建: $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"

JS_LIST="$(mktemp)"; CSS_LIST="$(mktemp)"; FONT_LIST="$(mktemp)"
trap 'rm -f "$JS_LIST" "$CSS_LIST" "$FONT_LIST"' EXIT

echo "抓首页 HTML ..."
HTML="$("${CURL[@]}" "$BASE/")"
printf '%s' "$HTML" | grep -oE '/_next/static/chunks/[A-Za-z0-9/._-]+\.js'  >> "$JS_LIST"  || true
printf '%s' "$HTML" | grep -oE '/_next/static/css/[A-Za-z0-9._-]+\.css'     >> "$CSS_LIST" || true

# webpack 运行时:显式列出的全部 chunk
WP_PATH="$(printf '%s' "$HTML" | grep -oE '/_next/static/chunks/webpack-[a-f0-9]+\.js' | head -1)"
if [ -n "$WP_PATH" ]; then
  echo "解析 webpack 运行时 ..."
  WP="$("${CURL[@]}" "$BASE$WP_PATH")"
  printf '%s' "$WP" | grep -oE 'static/chunks/[A-Za-z0-9/._-]+\.js' | sed 's#^#/_next/#' >> "$JS_LIST" || true
fi

# 每个路由的 RSC → 该路由需要的全部 chunk(含 app/forms/.../page-*.js 这种路由专属 chunk)
for r in "${ROUTES[@]}"; do
  echo "抓路由 RSC: $r"
  RSC="$("${CURL[@]}" -H 'RSC: 1' "$BASE$r?_rsc=warm")" || RSC=""
  printf '%s' "$RSC" | grep -oE 'static/chunks/[A-Za-z0-9/._-]+\.js' | sed 's#^#/_next/#' >> "$JS_LIST" || true
done

# CSS 里引用的字体
sort -u "$CSS_LIST" | while read -r c; do
  [ -z "$c" ] && continue
  CSS="$("${CURL[@]}" "$BASE$c")"
  printf '%s' "$CSS" | grep -oE '/_next/static/media/[A-Za-z0-9/._-]+\.(ttf|woff2|woff|otf)' >> "$FONT_LIST" || true
done

mime_of() {
  case "$1" in
    *.js) echo "application/javascript";; *.css) echo "text/css";;
    *.ttf) echo "font/ttf";; *.woff2) echo "font/woff2";; *.woff) echo "font/woff";; *.otf) echo "font/otf";;
    *) echo "application/octet-stream";;
  esac
}

mapfile -t JS   < <(sort -u "$JS_LIST")
mapfile -t CSS  < <(sort -u "$CSS_LIST")
mapfile -t FONT < <(sort -u "$FONT_LIST")
ALL=("${JS[@]}" "${CSS[@]}" "${FONT[@]}")

MANIFEST="$OUT/manifest.json"
echo "[" > "$MANIFEST"
# 首页 HTML 也打进内置包:首启即从包里出、零预热;运行时版本校验再更新沙箱副本
printf '%s' "$HTML" > "$OUT/home.html"
hsz=$(wc -c < "$OUT/home.html" | tr -d ' ')
printf '  {"url":"%s/","file":"home.html","mime":"text/html"}' "$BASE" >> "$MANIFEST"
n=1
printf '  + %-58s %8s B  %s\n' "home.html" "$hsz" "text/html"
for u in "${ALL[@]}"; do
  [ -z "$u" ] && continue
  file="$(printf '%s' "$u" | sed 's#^/_next/static/##; s#/#_#g')"
  if ! "${DL[@]}" "$BASE$u" -o "$OUT/$file"; then
    printf '  - skip (HTTP err) %s\n' "$u"; continue
  fi
  [ -s "$OUT/$file" ] || { rm -f "$OUT/$file"; continue; }
  sz=$(wc -c < "$OUT/$file" | tr -d ' ')
  mime="$(mime_of "$u")"
  [ $n -gt 0 ] && echo "," >> "$MANIFEST"
  printf '  {"url":"%s%s","file":"%s","mime":"%s"}' "$BASE" "$u" "$file" "$mime" >> "$MANIFEST"
  n=$((n+1))
  printf '  + %-58s %8s B  %s\n' "$file" "$sz" "$mime"
done
printf '\n]\n' >> "$MANIFEST"

echo "----------------------------------------"
echo "路由: ${ROUTES[*]}"
echo "已打包 $n 个资源 → $OUT"