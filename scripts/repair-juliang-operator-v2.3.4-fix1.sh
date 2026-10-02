#!/bin/sh
set -eu

PIN="d104585e412aace85ff73d5d1b03c78b9a002e9e"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
TMP="/tmp/jfa-op-fix1-$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang Operator 2.3.4 Fix1"
echo " session expiry + blank login + hide iStore"
echo "=================================================="

fetch(){
  src="$1"; dst="$2"
  curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$dst" "$BASE/$src"
  [ -s "$dst" ]
}

fetch usr/libexec/juliang-operator-patch.lua "$TMP/juliang-operator-patch.lua"
fetch usr/share/rpcd/acl.d/juliang-operator.json "$TMP/juliang-operator.json"
fetch usr/share/luci/menu.d/zz-juliang-operator.json "$TMP/zz-juliang-operator.json"

lua -e 'assert(loadfile("'"$TMP"'/juliang-operator-patch.lua"))'

cp -af "$TMP/juliang-operator-patch.lua" /usr/libexec/juliang-operator-patch.lua
cp -af "$TMP/juliang-operator.json" /usr/share/rpcd/acl.d/juliang-operator.json
cp -af "$TMP/zz-juliang-operator.json" /usr/share/luci/menu.d/zz-juliang-operator.json
chmod 0644 /usr/libexec/juliang-operator-patch.lua   /usr/share/rpcd/acl.d/juliang-operator.json   /usr/share/luci/menu.d/zz-juliang-operator.json

echo "[INFO] removing old iStore POST guard, hiding iStore routes and blanking login username..."
lua /usr/libexec/juliang-operator-patch.lua

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true

# New sessions must pick up the corrected ACL. Existing web sessions will be
# invalidated once here; SSH is unaffected.
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "===== Operator ====="
/usr/bin/juliang-operator status 2>/dev/null || true

echo
echo "===== Fix1 checks ====="
grep -q '"session"' /usr/share/rpcd/acl.d/juliang-operator.json && echo "OK: session ACL"
grep -q '"admin/istorex"' /usr/share/luci/menu.d/zz-juliang-operator.json && echo "OK: iStore route hidden"
if grep -q 'JULIANG_OPERATOR_ISTORE_V234' /usr/lib/lua/luci/controller/istore_backend.lua 2>/dev/null; then
  echo "WARN: old iStore POST guard still present"
else
  echo "OK: old iStore POST guard removed"
fi
if grep -R -q 'name="luci_username" value=""' /usr/share/ucode/luci/template /usr/lib/lua/luci/view 2>/dev/null; then
  echo "OK: login username default is blank"
else
  echo "WARN: no patched sysauth template found"
fi

echo
echo "[OK] Operator Fix1 installed"
echo "[INFO] All LuCI browser sessions were intentionally reset once."
echo "[INFO] Open a private/incognito window and log in again with the operator account."
