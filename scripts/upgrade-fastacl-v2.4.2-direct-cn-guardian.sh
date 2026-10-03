#!/bin/sh
set -eu

REPO="wangjontao/Actions-OpenWrt"
PIN="710bd4eb5f59cdbe1928b04f635666d0b1a3c307"
API="https://api.github.com/repos/$REPO/contents"
TMP="/tmp/jfa242-routefix-$$"
BACKUP="/etc/juliang-fastacl/v2.4.2-routefix-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$TMP" "$BACKUP"

get(){
  path="$1"; out="$2"
  mkdir -p "$(dirname "$out")"
  curl -4 --http1.1 -fsSL --connect-timeout 15 --max-time 90 --retry 5 --retry-delay 1 \
    -H 'Accept: application/vnd.github.raw+json' \
    -H 'User-Agent: FastACL-242-RouteFix' \
    -o "$out" "$API/$path?ref=$PIN"
  [ -s "$out" ] || { echo "[ERROR] empty payload: $path" >&2; exit 1; }
}

cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

echo "=================================================="
echo " FastACL 2.4.2 Route/Guardian Fix"
echo " Guardian + main LAN direct + per-wireless mode"
echo "=================================================="

command -v curl >/dev/null 2>&1 || { echo '[ERROR] curl not found' >&2; exit 1; }
command -v lua >/dev/null 2>&1 || { echo '[ERROR] lua not found' >&2; exit 1; }
command -v nft >/dev/null 2>&1 || { echo '[ERROR] nft not found' >&2; exit 1; }

get "profiles/fastacl-v9/root/usr/bin/juliang-fastacl-mode" "$TMP/juliang-fastacl-mode"
get "profiles/fastacl-v9/root/usr/bin/juliang-fastacl-guard" "$TMP/juliang-fastacl-guard"
get "profiles/fastacl-v9/root/usr/lib/lua/luci/controller/juliang_fastacl_mode.lua" "$TMP/juliang_fastacl_mode.lua"
get "profiles/fastacl-v9/root/www/luci-static/resources/juliang-fastacl-v242-routing.js" "$TMP/juliang-fastacl-v242-routing.js"

sh -n "$TMP/juliang-fastacl-mode"
sh -n "$TMP/juliang-fastacl-guard"
lua -e "assert(loadfile('$TMP/juliang_fastacl_mode.lua'))"
grep -q '无线出口模式' "$TMP/juliang-fastacl-v242-routing.js"

echo "[OK] payload preflight"

for p in \
  /usr/bin/juliang-fastacl-mode \
  /usr/bin/juliang-fastacl-guard \
  /usr/lib/lua/luci/controller/juliang_fastacl_mode.lua \
  /www/luci-static/resources/juliang-fastacl-v242-routing.js \
  /usr/lib/lua/luci/view/juliang_fastacl/console.htm; do
  if [ -e "$p" ]; then
    mkdir -p "$BACKUP/$(dirname "${p#/}")"
    cp -af "$p" "$BACKUP/${p#/}"
  fi
done

cp -af "$TMP/juliang-fastacl-mode" /usr/bin/juliang-fastacl-mode
cp -af "$TMP/juliang-fastacl-guard" /usr/bin/juliang-fastacl-guard
chmod 0755 /usr/bin/juliang-fastacl-mode /usr/bin/juliang-fastacl-guard
mkdir -p /usr/lib/lua/luci/controller /www/luci-static/resources
cp -af "$TMP/juliang_fastacl_mode.lua" /usr/lib/lua/luci/controller/juliang_fastacl_mode.lua
cp -af "$TMP/juliang-fastacl-v242-routing.js" /www/luci-static/resources/juliang-fastacl-v242-routing.js
chmod 0644 /usr/lib/lua/luci/controller/juliang_fastacl_mode.lua /www/luci-static/resources/juliang-fastacl-v242-routing.js

JFA_CONSOLE=/usr/lib/lua/luci/view/juliang_fastacl/console.htm lua <<'LUA'
local path=assert(os.getenv('JFA_CONSOLE'))
local f=assert(io.open(path,'rb')); local s=f:read('*a'); f:close()
local marker='juliang-fastacl-v242-routing.js?v=2422'
if not s:find(marker,1,true) then
  local foot='<%+footer%>'
  local p=s:find(foot,1,true)
  assert(p,'console footer not found')
  local tag='<script type="text/javascript" src="/luci-static/resources/juliang-fastacl-v242-routing.js?v=2422"></script>\n'
  s=s:sub(1,p-1)..tag..s:sub(p)
  local o=assert(io.open(path,'wb')); o:write(s); o:close()
end
LUA

grep -q 'juliang-fastacl-v242-routing.js?v=2422' /usr/lib/lua/luci/view/juliang_fastacl/console.htm

# Main LAN / main WiFi becomes direct by default when it has no assigned node.
# Existing AP/VLAN networks retain proxy/fail-closed semantics until changed
# explicitly in the new per-wireless UI.
/usr/bin/juliang-fastacl-mode apply

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

# Previous Lite installer only enabled the service and manually repaired the
# data plane, which left the procd Guardian process stopped. Restart it now.
/etc/init.d/juliang-fastacl enable >/dev/null 2>&1 || true
/etc/init.d/juliang-fastacl restart >/tmp/juliang-fastacl/routefix-service.log 2>&1
sleep 2

if /etc/init.d/juliang-fastacl running >/dev/null 2>&1 || ps w 2>/dev/null | grep '[j]uliang-fastacl-guard' >/dev/null 2>&1; then
  echo "[OK] Guardian running"
else
  echo "[ERROR] Guardian did not start; see /tmp/juliang-fastacl/routefix-service.log" >&2
  exit 1
fi

/usr/bin/juliang-fastacl-mode apply

uci set juliang_fastacl.main.version='2.4.2'
uci commit juliang_fastacl

echo "[OK] FastACL 2.4.2 routing-mode fix installed"
echo "[OK] Main WiFi + wired LAN: domestic direct by default when unassigned"
echo "[OK] Per wireless: 国内直连 / 代理节点"
echo "[OK] Assigning a node automatically means proxy mode"
echo "[INFO] Backup: $BACKUP"
echo "[INFO] Ctrl+F5 refresh FastACL console"
