#!/bin/sh
set -eu

PIN="beb69a104414cb8364c0ec13b010e6f8af952bcc"
URL="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root/usr/lib/lua/luci/view/juliang_fastacl/console.htm"
DST="/usr/lib/lua/luci/view/juliang_fastacl/console.htm"
TMP="/tmp/jfa-ui-polish-$$"

echo "=================================================="
echo " JuLiang FastACL UI Polish 2.3.1"
echo " import prominence + row separation + probe result"
echo "=================================================="

mkdir -p /etc/juliang-fastacl /usr/lib/lua/luci/view/juliang_fastacl
curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$TMP" "$URL"
[ -s "$TMP" ]

grep -q '＋ 导入节点' "$TMP"
grep -q 'jfa-probe-result' "$TMP"
grep -q '检测成功：' "$TMP"
! grep -q '无线数量自动读取，不固定 5/10/20' "$TMP"

cp -af "$DST" /etc/juliang-fastacl/console.htm.pre-ui-polish-231 2>/dev/null || true
cp -af "$TMP" "$DST"
chmod 0644 "$DST"
rm -f "$TMP"

rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] UI polish installed"
echo "[OK] FastACL engine/runtime untouched"
echo "[OK] node import is now prominent and rounded"
echo "[OK] node rows are visually separated"
echo "[OK] probe result remains visible in the node row"
echo "[INFO] browser: Ctrl+F5 -> Services -> FastACL 控制台"
