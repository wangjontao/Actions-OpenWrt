#!/bin/sh
set -eu

PIN="d7de6bbf62e23cac8df071f503e3a66ffc74e9e8"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
TMP="/tmp/jfa-mainlan-$$"
BK="/etc/juliang-fastacl/mainlan-backup"
mkdir -p "$TMP" "$BK" /tmp/juliang-fastacl
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang FastACL 2.3.2 Main LAN Support"
echo " main WiFi + wired LAN assignable target"
echo "=================================================="

fetch(){
  src="$1"; dst="$2"
  curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$dst" "$BASE/$src"
  [ -s "$dst" ]
}

fetch usr/bin/juliang-fastacl "$TMP/juliang-fastacl"
fetch usr/libexec/juliang-fastacl-discover.lua "$TMP/juliang-fastacl-discover.lua"
fetch usr/lib/lua/luci/view/juliang_fastacl/console.htm "$TMP/console.htm"

sh -n "$TMP/juliang-fastacl"
lua -e 'assert(loadfile("'"$TMP"'/juliang-fastacl-discover.lua"))'
grep -q '主网络 · ' "$TMP/juliang-fastacl-discover.lua"
grep -q 'topology_ready' "$TMP/juliang-fastacl"
grep -q '同时支持 SOCKS5/SOCKS/HTTP 与多行 SK5 简写。' "$TMP/console.htm"

cp -af /usr/bin/juliang-fastacl "$BK/juliang-fastacl.pre-mainlan" 2>/dev/null || true
cp -af /usr/libexec/juliang-fastacl-discover.lua "$BK/juliang-fastacl-discover.lua.pre-mainlan" 2>/dev/null || true
cp -af /usr/lib/lua/luci/view/juliang_fastacl/console.htm "$BK/console.htm.pre-mainlan" 2>/dev/null || true
cp -af /etc/config/juliang_fastacl "$BK/juliang_fastacl.uci.pre-mainlan" 2>/dev/null || true

cp -af "$TMP/juliang-fastacl" /usr/bin/juliang-fastacl
cp -af "$TMP/juliang-fastacl-discover.lua" /usr/libexec/juliang-fastacl-discover.lua
cp -af "$TMP/console.htm" /usr/lib/lua/luci/view/juliang_fastacl/console.htm
chmod 0755 /usr/bin/juliang-fastacl
chmod 0644 /usr/libexec/juliang-fastacl-discover.lua /usr/lib/lua/luci/view/juliang_fastacl/console.htm

uci -q get juliang_fastacl.main >/dev/null 2>&1 || uci set juliang_fastacl.main='main'
uci set juliang_fastacl.main.include_lan='1'
uci commit juliang_fastacl

echo "[INFO] discovering AP networks + main LAN..."
/usr/bin/juliang-fastacl discover >/tmp/juliang-fastacl/mainlan-discover.json 2>/tmp/juliang-fastacl/mainlan-discover.log || {
  cat /tmp/juliang-fastacl/mainlan-discover.log 2>/dev/null || true
  echo "[ERROR] discovery failed"
  exit 1
}

/usr/bin/juliang-fastacl save-state >/dev/null 2>&1 || true

rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "===== FastACL topology ====="
/usr/bin/juliang-fastacl status

echo
echo "===== main LAN slot ====="
uci -q show juliang_fastacl | grep -E "\.network='lan'|\.ssid='主网络" || true

echo
echo "[OK] main WiFi/wired LAN is now available as one FastACL assignment target"
echo "[INFO] existing A1..An slots are kept in the same order; main LAN is appended last"
echo "[INFO] assign a node to '主网络 ... 有线LAN' from FastACL 控制台"
echo "[INFO] the first assignment to this new subnet reloads TProxy/nft once; later switches stay on the fast path"
