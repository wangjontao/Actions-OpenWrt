#!/bin/sh
set -eu

PIN="fb68d06e08fdd5590c144ceec0695c98fb6ba69a"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
TMP="/tmp/jfa-op-238-$$"
BK="/etc/juliang-fastacl/operator-238-backup"
mkdir -p "$TMP" "$BK"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang Operator 2.3.8"
echo " WAN monitor + live traffic + WiFi client details"
echo "=================================================="

fetch(){
  src="$1"; dst="$2"
  curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$dst" "$BASE/$src"
  [ -s "$dst" ]
}

fetch usr/lib/lua/luci/controller/juliang_operator.lua "$TMP/juliang_operator.lua"
fetch usr/lib/lua/luci/view/juliang_operator/home.htm "$TMP/home.htm"
fetch usr/lib/lua/luci/view/juliang_operator/wireless.htm "$TMP/wireless.htm"

lua -e 'assert(loadfile("'"$TMP"'/juliang_operator.lua"))'
grep -q 'handle_dashboard' "$TMP/juliang_operator.lua"
grep -q 'action == "clients"' "$TMP/juliang_operator.lua"
grep -q '实时网络流量' "$TMP/home.htm"
grep -q '已连接设备' "$TMP/wireless.htm"

cp -af /usr/lib/lua/luci/controller/juliang_operator.lua "$BK/juliang_operator.lua.pre238" 2>/dev/null || true
cp -af /usr/lib/lua/luci/view/juliang_operator/home.htm "$BK/home.htm.pre238" 2>/dev/null || true
cp -af /usr/lib/lua/luci/view/juliang_operator/wireless.htm "$BK/wireless.htm.pre238" 2>/dev/null || true

mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/juliang_operator
cp -af "$TMP/juliang_operator.lua" /usr/lib/lua/luci/controller/juliang_operator.lua
cp -af "$TMP/home.htm" /usr/lib/lua/luci/view/juliang_operator/home.htm
cp -af "$TMP/wireless.htm" /usr/lib/lua/luci/view/juliang_operator/wireless.htm
chmod 0644   /usr/lib/lua/luci/controller/juliang_operator.lua   /usr/lib/lua/luci/view/juliang_operator/home.htm   /usr/lib/lua/luci/view/juliang_operator/wireless.htm

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "===== 2.3.8 checks ====="
grep -q 'handle_dashboard' /usr/lib/lua/luci/controller/juliang_operator.lua   && echo "OK: WAN/traffic dashboard API installed"
grep -q 'action == "clients"' /usr/lib/lua/luci/controller/juliang_operator.lua   && echo "OK: WiFi client inventory API installed"
grep -q '实时网络流量' /usr/lib/lua/luci/view/juliang_operator/home.htm   && echo "OK: live traffic dashboard installed"
grep -q '已连接设备' /usr/lib/lua/luci/view/juliang_operator/wireless.htm   && echo "OK: per-SSID device table installed"

echo
echo "[OK] Operator 2.3.8 installed"
echo "[INFO] refresh the operator homepage and Wireless page."
