#!/bin/sh
set -eu

PIN="4927e1de2e89030e3f4d57d4f50a3fbdffe8b67f"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
TMP="/tmp/jfa-op-ui-$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang Operator 2.3.6"
echo " custom home + safe wireless editor + RPC fix"
echo "=================================================="

fetch(){
  src="$1"; dst="$2"
  curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$dst" "$BASE/$src"
  [ -s "$dst" ]
}

fetch usr/libexec/juliang-operator-patch.lua "$TMP/juliang-operator-patch.lua"
fetch usr/lib/lua/luci/controller/juliang_operator.lua "$TMP/juliang_operator.lua"
fetch usr/lib/lua/luci/view/juliang_operator/home.htm "$TMP/home.htm"
fetch usr/lib/lua/luci/view/juliang_operator/wireless.htm "$TMP/wireless.htm"
fetch usr/share/rpcd/acl.d/juliang-operator.json "$TMP/juliang-operator.json"
fetch usr/share/luci/menu.d/zz-juliang-operator.json "$TMP/zz-juliang-operator.json"

lua -e 'assert(loadfile("'"$TMP"'/juliang-operator-patch.lua"))'
lua -e 'assert(loadfile("'"$TMP"'/juliang_operator.lua"))'
grep -q 'JULIANG_OPERATOR_HOME_GATE_V236' "$TMP/juliang-operator-patch.lua"
grep -q '"getFeatures"' "$TMP/juliang-operator.json"
grep -q '无线设置' "$TMP/wireless.htm"

mkdir -p /usr/lib/lua/luci/controller   /usr/lib/lua/luci/view/juliang_operator   /usr/libexec   /usr/share/rpcd/acl.d   /usr/share/luci/menu.d

cp -af "$TMP/juliang-operator-patch.lua" /usr/libexec/juliang-operator-patch.lua
cp -af "$TMP/juliang_operator.lua" /usr/lib/lua/luci/controller/juliang_operator.lua
cp -af "$TMP/home.htm" /usr/lib/lua/luci/view/juliang_operator/home.htm
cp -af "$TMP/wireless.htm" /usr/lib/lua/luci/view/juliang_operator/wireless.htm
cp -af "$TMP/juliang-operator.json" /usr/share/rpcd/acl.d/juliang-operator.json
cp -af "$TMP/zz-juliang-operator.json" /usr/share/luci/menu.d/zz-juliang-operator.json

chmod 0644 /usr/libexec/juliang-operator-patch.lua   /usr/lib/lua/luci/controller/juliang_operator.lua   /usr/lib/lua/luci/view/juliang_operator/home.htm   /usr/lib/lua/luci/view/juliang_operator/wireless.htm   /usr/share/rpcd/acl.d/juliang-operator.json   /usr/share/luci/menu.d/zz-juliang-operator.json

echo "[INFO] applying custom home and restoring stock root wireless page..."
lua /usr/libexec/juliang-operator-patch.lua

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true

/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "===== Operator ====="
/usr/bin/juliang-operator status 2>/dev/null || true

echo
echo "===== 2.3.6 checks ====="
grep -q 'JULIANG_OPERATOR_HOME_GATE_V236' /usr/lib/lua/luci/view/quickstart/home.htm   && echo "OK: QuickStart operator gate installed"
grep -q 'JuLiang 控制中心' /usr/lib/lua/luci/view/juliang_operator/home.htm   && echo "OK: custom operator home installed"
grep -q '无线设置' /usr/lib/lua/luci/view/juliang_operator/wireless.htm   && echo "OK: safe wireless editor installed"
grep -q '"getFeatures"' /usr/share/rpcd/acl.d/juliang-operator.json   && echo "OK: luci/getFeatures ACL installed"
if [ -f /usr/share/luci/menu.d/luci-app-istorex.json ]; then
  grep -q 'juliang-quickstart-admin' /usr/share/luci/menu.d/luci-app-istorex.json     && echo "OK: iStore hidden from operator"
fi

echo
echo "[OK] Operator 2.3.6 installed"
echo "[INFO] LuCI sessions were reset once. Use a private/incognito window and log in again."
