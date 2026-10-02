#!/bin/sh
set -eu

PIN="48ecf2453eb6f023d6bdcb8843fe07b315ae2d51"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
TMP="/tmp/jfa-operator-$$"
BK="/etc/juliang-fastacl/operator-backup"
mkdir -p "$TMP" "$BK" /tmp/juliang-fastacl
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang FastACL 2.3.4 Operator Mode"
echo " LuCI-only restricted user + read-only iStore/WiFi"
echo "=================================================="

fetch(){
  src="$1"; dst="$2"
  curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$dst" "$BASE/$src"
  [ -s "$dst" ]
}

fetch usr/bin/juliang-operator "$TMP/juliang-operator"
fetch usr/libexec/juliang-operator-patch.lua "$TMP/juliang-operator-patch.lua"
fetch usr/share/rpcd/acl.d/juliang-operator.json "$TMP/juliang-operator.json"
fetch usr/share/luci/menu.d/zz-juliang-operator.json "$TMP/zz-juliang-operator.json"
fetch usr/lib/lua/luci/controller/juliang_fastacl.lua "$TMP/juliang_fastacl.lua"
fetch usr/lib/lua/luci/view/juliang_fastacl/console.htm "$TMP/console.htm"

sh -n "$TMP/juliang-operator"
lua -e 'assert(loadfile("'"$TMP"'/juliang-operator-patch.lua"))'
lua -e 'assert(loadfile("'"$TMP"'/juliang_fastacl.lua"))'

cp -af /usr/lib/lua/luci/controller/juliang_fastacl.lua "$BK/juliang_fastacl.lua.pre-operator" 2>/dev/null || true
cp -af /usr/lib/lua/luci/view/juliang_fastacl/console.htm "$BK/console.htm.pre-operator" 2>/dev/null || true

cp -af "$TMP/juliang-operator" /usr/bin/juliang-operator
cp -af "$TMP/juliang-operator-patch.lua" /usr/libexec/juliang-operator-patch.lua
mkdir -p /usr/share/rpcd/acl.d /usr/share/luci/menu.d /usr/lib/lua/luci/view/juliang_fastacl
cp -af "$TMP/juliang-operator.json" /usr/share/rpcd/acl.d/juliang-operator.json
cp -af "$TMP/zz-juliang-operator.json" /usr/share/luci/menu.d/zz-juliang-operator.json
cp -af "$TMP/juliang_fastacl.lua" /usr/lib/lua/luci/controller/juliang_fastacl.lua
cp -af "$TMP/console.htm" /usr/lib/lua/luci/view/juliang_fastacl/console.htm
chmod 0755 /usr/bin/juliang-operator
chmod 0644 /usr/libexec/juliang-operator-patch.lua /usr/share/rpcd/acl.d/juliang-operator.json /usr/share/luci/menu.d/zz-juliang-operator.json /usr/lib/lua/luci/controller/juliang_fastacl.lua /usr/lib/lua/luci/view/juliang_fastacl/console.htm

echo "[INFO] patching QuickStart/iStore/Wireless menu..."
lua /usr/libexec/juliang-operator-patch.lua

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "===== Installed ====="
echo "OK: operator ACL"
echo "OK: operator menu policy"
echo "OK: FastACL restricted route + internal importer"
echo "OK: iStore operator view is read-only"
echo "OK: Wireless operator view is read-only"
echo
echo "[IMPORTANT] No operator account has been created yet."
echo "Run: juliang-operator setup"
