#!/bin/sh
set -eu

PIN="a382ec6c6f3423fcbb51efe1d98cc0ec2a4cb6b1"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
TMP="/tmp/jfa-op-home-$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang Operator 2.3.5"
echo " custom minimalist home + RPC fix + hide iStore"
echo "=================================================="

fetch(){
  src="$1"; dst="$2"
  curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$dst" "$BASE/$src"
  [ -s "$dst" ]
}

fetch usr/libexec/juliang-operator-patch.lua "$TMP/juliang-operator-patch.lua"
fetch usr/share/rpcd/acl.d/juliang-operator.json "$TMP/juliang-operator.json"
fetch usr/share/luci/menu.d/zz-juliang-operator.json "$TMP/zz-juliang-operator.json"
fetch usr/lib/lua/luci/view/juliang_operator/home.htm "$TMP/home.htm"

lua -e 'assert(loadfile("'"$TMP"'/juliang-operator-patch.lua"))'
grep -q 'JULIANG_OPERATOR_HOME_V235' "$TMP/juliang-operator-patch.lua"
grep -q '"getFeatures"' "$TMP/juliang-operator.json"
grep -q 'JuLiang 控制中心' "$TMP/home.htm"

mkdir -p /usr/lib/lua/luci/view/juliang_operator /usr/share/rpcd/acl.d /usr/share/luci/menu.d
cp -af "$TMP/juliang-operator-patch.lua" /usr/libexec/juliang-operator-patch.lua
cp -af "$TMP/juliang-operator.json" /usr/share/rpcd/acl.d/juliang-operator.json
cp -af "$TMP/zz-juliang-operator.json" /usr/share/luci/menu.d/zz-juliang-operator.json
cp -af "$TMP/home.htm" /usr/lib/lua/luci/view/juliang_operator/home.htm
chmod 0644 /usr/libexec/juliang-operator-patch.lua   /usr/share/rpcd/acl.d/juliang-operator.json   /usr/share/luci/menu.d/zz-juliang-operator.json   /usr/lib/lua/luci/view/juliang_operator/home.htm

echo "[INFO] switching operator homepage away from iStore/QuickStart..."
lua /usr/libexec/juliang-operator-patch.lua

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true

/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "===== Operator ====="
/usr/bin/juliang-operator status 2>/dev/null || true

echo
echo "===== 2.3.5 checks ====="
grep -q 'JULIANG_OPERATOR_HOME_V235' /usr/lib/lua/luci/controller/quickstart.lua && echo "OK: operator uses custom home"
grep -q 'JuLiang 控制中心' /usr/lib/lua/luci/view/juliang_operator/home.htm && echo "OK: minimalist home installed"
grep -q '"getFeatures"' /usr/share/rpcd/acl.d/juliang-operator.json && echo "OK: luci/getFeatures allowed"
if [ -f /usr/share/luci/menu.d/luci-app-istorex.json ]; then
  grep -q 'juliang-quickstart-admin' /usr/share/luci/menu.d/luci-app-istorex.json && echo "OK: iStore menu hidden from operator"
else
  echo "OK: no iStore menu file present"
fi

echo
echo "[OK] Operator 2.3.5 installed"
echo "[INFO] all LuCI sessions were reset once"
echo "[INFO] open a private/incognito window and log in again"
