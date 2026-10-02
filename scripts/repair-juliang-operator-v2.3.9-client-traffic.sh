#!/bin/sh
set -eu

PIN="2a768dee995a2a819e470c09b9dc918d49fb1198"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
TMP="/tmp/jfa-op-239-$$"
BK="/etc/juliang-fastacl/operator-239-backup"
mkdir -p "$TMP" "$BK"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang Operator 2.3.9"
echo " per-client real traffic + wireless UI polish"
echo "=================================================="

fetch(){
  src="$1"; dst="$2"
  curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$dst" "$BASE/$src"
  [ -s "$dst" ]
}

fetch usr/lib/lua/luci/controller/juliang_operator.lua "$TMP/juliang_operator.lua"
fetch usr/lib/lua/luci/view/juliang_operator/wireless.htm "$TMP/wireless.htm"

lua -e 'assert(loadfile("'"$TMP"'/juliang_operator.lua"))'
grep -q 'juliang_operator_stats' "$TMP/juliang_operator.lua"
grep -q 'router_down_bytes' "$TMP/juliang_operator.lua"
! grep -q '不开放接口、DHCP、防火墙' "$TMP/wireless.htm"

cp -af /usr/lib/lua/luci/controller/juliang_operator.lua "$BK/juliang_operator.lua.pre239" 2>/dev/null || true
cp -af /usr/lib/lua/luci/view/juliang_operator/wireless.htm "$BK/wireless.htm.pre239" 2>/dev/null || true

cp -af "$TMP/juliang_operator.lua" /usr/lib/lua/luci/controller/juliang_operator.lua
cp -af "$TMP/wireless.htm" /usr/lib/lua/luci/view/juliang_operator/wireless.htm
chmod 0644   /usr/lib/lua/luci/controller/juliang_operator.lua   /usr/lib/lua/luci/view/juliang_operator/wireless.htm

# Clear only the Operator UI caches. FastACL relays stay untouched.
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "===== 2.3.9 checks ====="
grep -q 'juliang_operator_stats' /usr/lib/lua/luci/controller/juliang_operator.lua   && echo "OK: per-client nft traffic counters installed"
grep -q 'router_down_bytes' /usr/lib/lua/luci/controller/juliang_operator.lua   && echo "OK: wireless page will use router traffic counters"
if grep -q '不开放接口、DHCP、防火墙' /usr/lib/lua/luci/view/juliang_operator/wireless.htm; then
  echo "WARN: old wireless description still present"
else
  echo "OK: customer-facing wireless description simplified"
fi

echo
echo "[OK] Operator 2.3.9 installed"
echo "[INFO] Open 网络 -> 无线, wait about 4 seconds, then generate traffic on a client."
echo "[INFO] The first sample shows 采样中; subsequent samples show live down/up speed."
