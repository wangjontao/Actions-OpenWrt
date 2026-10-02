#!/bin/sh
set -eu

PIN="e6fa95be0789bc6640f503a68a4670141cf813fd"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
TMP="/tmp/jfa-op-237-$$"
BK="/etc/juliang-fastacl/operator-237-backup"
mkdir -p "$TMP" "$BK"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang Operator 2.3.7"
echo " FastACL nodes + custom home + single wireless UI"
echo "=================================================="

fetch(){
  src="$1"; dst="$2"
  curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$dst" "$BASE/$src"
  [ -s "$dst" ]
}

fetch usr/lib/lua/luci/controller/juliang_fastacl.lua "$TMP/juliang_fastacl.lua"
fetch usr/lib/lua/luci/controller/juliang_operator.lua "$TMP/juliang_operator.lua"
fetch usr/lib/lua/luci/view/juliang_operator/home.htm "$TMP/home.htm"
fetch usr/lib/lua/luci/view/juliang_operator/wireless.htm "$TMP/wireless.htm"
fetch usr/libexec/juliang-operator-patch.lua "$TMP/juliang-operator-patch.lua"
fetch usr/share/rpcd/acl.d/juliang-operator.json "$TMP/juliang-operator.json"
fetch usr/share/luci/menu.d/zz-juliang-operator.json "$TMP/zz-juliang-operator.json"

lua -e 'assert(loadfile("'"$TMP"'/juliang_fastacl.lua"))'
lua -e 'assert(loadfile("'"$TMP"'/juliang_operator.lua"))'
lua -e 'assert(loadfile("'"$TMP"'/juliang-operator-patch.lua"))'
grep -q 'require("uci").cursor()' "$TMP/juliang_fastacl.lua"
grep -q 'require("uci").cursor()' "$TMP/juliang_operator.lua"
grep -q 'JuLiang 控制中心' "$TMP/home.htm"
grep -q '无线设置' "$TMP/wireless.htm"
! grep -q '"admin/network/wireless"' "$TMP/zz-juliang-operator.json"

cp -af /usr/lib/lua/luci/controller/juliang_fastacl.lua "$BK/juliang_fastacl.lua.pre237" 2>/dev/null || true
cp -af /usr/lib/lua/luci/controller/juliang_operator.lua "$BK/juliang_operator.lua.pre237" 2>/dev/null || true
cp -af /usr/share/luci/menu.d/zz-juliang-operator.json "$BK/zz-juliang-operator.json.pre237" 2>/dev/null || true

mkdir -p /usr/lib/lua/luci/controller   /usr/lib/lua/luci/view/juliang_operator   /usr/libexec   /usr/share/rpcd/acl.d   /usr/share/luci/menu.d

cp -af "$TMP/juliang_fastacl.lua" /usr/lib/lua/luci/controller/juliang_fastacl.lua
cp -af "$TMP/juliang_operator.lua" /usr/lib/lua/luci/controller/juliang_operator.lua
cp -af "$TMP/home.htm" /usr/lib/lua/luci/view/juliang_operator/home.htm
cp -af "$TMP/wireless.htm" /usr/lib/lua/luci/view/juliang_operator/wireless.htm
cp -af "$TMP/juliang-operator-patch.lua" /usr/libexec/juliang-operator-patch.lua
cp -af "$TMP/juliang-operator.json" /usr/share/rpcd/acl.d/juliang-operator.json
cp -af "$TMP/zz-juliang-operator.json" /usr/share/luci/menu.d/zz-juliang-operator.json

chmod 0644 /usr/lib/lua/luci/controller/juliang_fastacl.lua   /usr/lib/lua/luci/controller/juliang_operator.lua   /usr/lib/lua/luci/view/juliang_operator/home.htm   /usr/lib/lua/luci/view/juliang_operator/wireless.htm   /usr/libexec/juliang-operator-patch.lua   /usr/share/rpcd/acl.d/juliang-operator.json   /usr/share/luci/menu.d/zz-juliang-operator.json

echo "[INFO] forcing custom homepage and cleaning old wireless menu..."
lua /usr/libexec/juliang-operator-patch.lua

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true

/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "===== checks ====="
grep -q 'JULIANG_OPERATOR_HOME_V237' /usr/lib/lua/luci/view/quickstart/home.htm   && echo "OK: 首页已强制切换到 JuLiang 自定义首页"
if grep -q '"admin/network/wireless"' /usr/share/luci/menu.d/zz-juliang-operator.json 2>/dev/null; then
  echo "ERROR: 旧无线菜单仍存在"
else
  echo "OK: 旧无线菜单已移除"
fi
grep -q '"admin/network/wireless_operator"' /usr/share/luci/menu.d/zz-juliang-operator.json   && echo "OK: 新无线 UI 已启用"
grep -q 'require("uci").cursor()' /usr/lib/lua/luci/controller/juliang_fastacl.lua   && echo "OK: FastACL 节点读取已改为受控后端读取"

echo
echo "[OK] Operator 2.3.7 installed"
echo "[INFO] 所有 LuCI 会话会失效一次；请用无痕窗口重新登录测试。"
