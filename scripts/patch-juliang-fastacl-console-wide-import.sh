#!/bin/sh
set -eu

PIN="2542afb05eb840c6f2e2d249b8538ab5f461764c"
URL="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root/usr/lib/lua/luci/view/juliang_fastacl/console.htm"
DST="/usr/lib/lua/luci/view/juliang_fastacl/console.htm"
TMP="/tmp/jfa-console-ui-$$"

echo "=================================================="
echo " JuLiang FastACL Console UI Update"
echo " full-width + built-in node import"
echo "=================================================="

mkdir -p /usr/lib/lua/luci/view/juliang_fastacl /etc/juliang-fastacl
curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$TMP" "$URL"
[ -s "$TMP" ]

grep -q '批量导入节点' "$TMP"
grep -q 'IMPORT_API' "$TMP"
grep -q 'SK5 简写' "$TMP"

cp -af "$DST" /etc/juliang-fastacl/console.htm.pre-wide-import 2>/dev/null || true
cp -af "$TMP" "$DST"
chmod 0644 "$DST"
rm -f "$TMP"

rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] FastACL 控制台已更新"
echo "[OK] 主区域改为宽屏显示"
echo "[OK] 已增加“导入节点”窗口"
echo "[OK] 支持 URI + 多行 host:port:user:pass SK5 简写"
echo "[INFO] 浏览器 Ctrl+F5 后进入：服务 -> FastACL 控制台"
