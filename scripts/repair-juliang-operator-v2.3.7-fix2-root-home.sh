#!/bin/sh
set -eu

PIN="5634f375968d3476e49bed7ff8ea98391cc23907"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
TMP="/tmp/jfa-op-fix2-$$"
BK="/etc/juliang-fastacl/operator-fix2-backup"
mkdir -p "$TMP" "$BK"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang Operator 2.3.7 Fix2"
echo " restore ROOT homepage + operator-only custom home"
echo "=================================================="

fetch(){
  src="$1"; dst="$2"
  curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$dst" "$BASE/$src"
  [ -s "$dst" ]
}

fetch usr/libexec/juliang-operator-patch.lua "$TMP/juliang-operator-patch.lua"
fetch usr/lib/lua/luci/view/juliang_operator/home.htm "$TMP/home.htm"

lua -e 'assert(loadfile("'"$TMP"'/juliang-operator-patch.lua"))'
grep -q 'JULIANG_OPERATOR_HOME_GATE_V237_FIX2' "$TMP/juliang-operator-patch.lua"
grep -q '\[=\[' "$TMP/home.htm"

cp -af /usr/lib/lua/luci/view/quickstart/home.htm "$BK/quickstart-home.pre-fix2" 2>/dev/null || true
cp -af /usr/lib/lua/luci/view/juliang_operator/home.htm "$BK/operator-home.pre-fix2" 2>/dev/null || true
cp -af /usr/libexec/juliang-operator-patch.lua "$BK/operator-patch.pre-fix2" 2>/dev/null || true

mkdir -p /usr/lib/lua/luci/view/juliang_operator /usr/libexec
cp -af "$TMP/juliang-operator-patch.lua" /usr/libexec/juliang-operator-patch.lua
cp -af "$TMP/home.htm" /usr/lib/lua/luci/view/juliang_operator/home.htm
chmod 0644 /usr/libexec/juliang-operator-patch.lua /usr/lib/lua/luci/view/juliang_operator/home.htm

echo "[INFO] restoring stock QuickStart home for root and adding operator-only gate..."
lua /usr/libexec/juliang-operator-patch.lua

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true

/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "===== Fix2 checks ====="
grep -q 'JULIANG_OPERATOR_HOME_GATE_V237_FIX2' /usr/lib/lua/luci/view/quickstart/home.htm   && echo "OK: operator-only homepage gate installed"
grep -q 'quickstart/main' /usr/lib/lua/luci/view/quickstart/home.htm   && echo "OK: root QuickStart/iStore homepage fallback restored"
grep -q '\[=\[' /usr/lib/lua/luci/view/juliang_operator/home.htm   && echo "OK: custom operator homepage syntax fixed"

echo
echo "[OK] Fix2 installed"
echo "[INFO] all LuCI sessions were reset once"
echo "[INFO] ROOT login -> original QuickStart/iStore home"
echo "[INFO] Operator login -> JuLiang custom home"
