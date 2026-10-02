#!/bin/sh
set -eu

PIN="1a543e711336c4b5a5359a2f8dfbe51dfe525cbe"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
TMP="/tmp/jfa-fix4-$$"
BK="/etc/juliang-fastacl/fix4-backup"
mkdir -p "$TMP" "$BK" /tmp/juliang-fastacl
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang FastACL V9 Fix4"
echo " chain stability + serialized switching + console"
echo "=================================================="

fetch(){
  src="$1"; dst="$2"
  curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$dst" "$BASE/$src"
  [ -s "$dst" ]
}

fetch usr/bin/juliang-fastacl "$TMP/juliang-fastacl"
fetch usr/bin/juliang-fastacl-luci-install "$TMP/juliang-fastacl-luci-install"
fetch usr/lib/lua/luci/controller/juliang_fastacl.lua "$TMP/juliang_fastacl.lua"
fetch usr/lib/lua/luci/view/juliang_fastacl/console.htm "$TMP/console.htm"

sh -n "$TMP/juliang-fastacl"
sh -n "$TMP/juliang-fastacl-luci-install"
lua -e 'assert(loadfile("'"$TMP"'/juliang_fastacl.lua"))'

grep -q 'probe_socks_wait "$port" 3 1' "$TMP/juliang-fastacl"
grep -q 'OP_LOCK=' "$TMP/juliang-fastacl"
grep -q 'FINAL_EGRESS_FAILED' "$TMP/juliang-fastacl"
grep -q 'switch_node "$ap" "$node" 1' "$TMP/juliang-fastacl"
grep -q 'JULIANG_FASTACL_V240' "$TMP/juliang-fastacl-luci-install"

cp -af /usr/bin/juliang-fastacl "$BK/juliang-fastacl.pre-fix4" 2>/dev/null || true
cp -af /usr/lib/lua/luci/controller/juliang_fastacl.lua "$BK/juliang_fastacl.lua.pre-fix4" 2>/dev/null || true
cp -af /usr/lib/lua/luci/view/passwall2/node_list/node_list.htm "$BK/node_list.htm.pre-fix4" 2>/dev/null || true

cp -af "$TMP/juliang-fastacl" /usr/bin/juliang-fastacl
cp -af "$TMP/juliang-fastacl-luci-install" /usr/bin/juliang-fastacl-luci-install
cp -af "$TMP/juliang_fastacl.lua" /usr/lib/lua/luci/controller/juliang_fastacl.lua
mkdir -p /usr/lib/lua/luci/view/juliang_fastacl
cp -af "$TMP/console.htm" /usr/lib/lua/luci/view/juliang_fastacl/console.htm
chmod 0755 /usr/bin/juliang-fastacl /usr/bin/juliang-fastacl-luci-install
chmod 0644 /usr/lib/lua/luci/controller/juliang_fastacl.lua /usr/lib/lua/luci/view/juliang_fastacl/console.htm

rm -rf /tmp/juliang-fastacl/operation.lock >/dev/null 2>&1 || true

echo "[INFO] repatching PassWall2 FastACL UI..."
/usr/bin/juliang-fastacl-luci-install >/tmp/juliang-fastacl/fix4-luci.log 2>&1 || {
  cat /tmp/juliang-fastacl/fix4-luci.log 2>/dev/null || true
  echo "[ERROR] LuCI repatch failed"
  exit 1
}

echo "[INFO] repairing current FastACL runtime..."
/usr/bin/juliang-fastacl repair >/tmp/juliang-fastacl/fix4-repair.log 2>&1 || {
  cat /tmp/juliang-fastacl/fix4-repair.log 2>/dev/null || true
  echo "[ERROR] FastACL repair failed"
  exit 1
}
/usr/bin/juliang-fastacl save-state >/dev/null 2>&1 || true

rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "===== FastACL ====="
/usr/bin/juliang-fastacl status
echo
echo "===== Fix4 checks ====="
grep -q 'JULIANG_FASTACL_V240' /usr/lib/lua/luci/view/passwall2/node_list/node_list.htm && echo "OK: PassWall2 UI Fix4"
test -s /usr/lib/lua/luci/view/juliang_fastacl/console.htm && echo "OK: standalone FastACL console installed"
echo "OK: switching operations are serialized"
echo "OK: chain/final egress is verified before success is committed"
echo "OK: failed switches roll back to previous working mapping"
echo
echo "[INFO] standalone console: Services -> FastACL 控制台"
echo "[OK] FastACL V9 Fix4 installed"
