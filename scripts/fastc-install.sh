#!/bin/sh
set -eu
PIN="f4f3a3a0c3b8ff108c9ab87bb964f1e73d908694"
BASE="https://cdn.jsdelivr.net/gh/wangjontao/Actions-OpenWrt@$PIN/profiles/fastc-v010/root"
TMP="/tmp/fastc017-$$"
BACKUP="/etc/fastc/install-backup-$(date +%Y%m%d-%H%M%S)"
OLD_MODE="$(uci -q get fastc.main.mode 2>/dev/null || echo fastacl)"
OLD_ENABLED="$(uci -q get fastc.main.enabled 2>/dev/null || echo 0)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT INT TERM
get(){ mkdir -p "$(dirname "$2")"; curl -4 -fL --connect-timeout 8 --max-time 120 --retry 3 -o "$2" "$BASE/$1"; }

require_grep(){
  pat="$1"; file="$2"; label="$3"
  if ! grep -q "$pat" "$file"; then
    echo "[ERROR] validation failed: $label" >&2
    echo "[ERROR] expected: $pat" >&2
    echo "[ERROR] file: $file" >&2
    exit 1
  fi
  echo "[OK] validated: $label"
}

lua_check(){
  file="$1"; label="$2"
  if ! FC_LUA_CHECK="$file" lua -e 'local p=os.getenv("FC_LUA_CHECK"); assert(p and p ~= "", "FC_LUA_CHECK missing"); assert(loadfile(p))'; then
    echo "[ERROR] Lua syntax validation failed: $label" >&2
    echo "[ERROR] file: $file" >&2
    exit 1
  fi
  echo "[OK] Lua syntax: $label"
}

echo "=================================================="
echo " FastC 0.1.7-dev Installer"
echo " auto wireless discovery + real selector sync"
echo " robust exit probe + TProxy + chain + Guardian"
echo "=================================================="
mkdir -p "$TMP" "$BACKUP" /etc/fastc

FILES="etc/config/fastc usr/bin/fastc-core usr/bin/fastc-dataplane usr/bin/fastc-mode usr/bin/fastc-guard etc/init.d/fastc usr/lib/lua/luci/controller/fastc.lua usr/lib/lua/luci/controller/fastc_runtime.lua usr/lib/lua/luci/controller/fastc_topology.lua usr/lib/lua/luci/view/fastc/console.htm usr/libexec/fastc-import.lua usr/libexec/fastc-generate.lua usr/libexec/fastc-discover.lua usr/libexec/fastc-sync.lua usr/share/rpcd/acl.d/fastc.json"
for f in $FILES; do
  [ -f "/$f" ] && { mkdir -p "$BACKUP/$(dirname "$f")"; cp -af "/$f" "$BACKUP/$f"; } || true
  get "$f" "$TMP/$f"
  [ -s "$TMP/$f" ] || { echo "[ERROR] empty component: $f" >&2; exit 1; }
  echo "[OK] downloaded: $f"
done

echo "[INFO] validating FastC 0.1.7 components..."
require_grep "option version '0.1.7-dev'" "$TMP/etc/config/fastc" "version 0.1.7-dev"
require_grep 'topology.json' "$TMP/usr/libexec/fastc-discover.lua" "wireless topology database"
require_grep 'uci:foreach("wireless","wifi-iface"' "$TMP/usr/libexec/fastc-discover.lua" "OpenWrt wireless auto discovery"
require_grep 'TOPO = "/etc/fastc/topology.json"' "$TMP/usr/libexec/fastc-generate.lua" "topology-driven generator"
require_grep 'default-selected:' "$TMP/usr/libexec/fastc-generate.lua" "deterministic selector selection"
require_grep 'store-selected: false' "$TMP/usr/libexec/fastc-generate.lua" "disable stale selector cache"
require_grep 'FASTC-DNS-HIJACK' "$TMP/usr/libexec/fastc-generate.lua" "client DNS hijack"
require_grep 'dialer-proxy:' "$TMP/usr/libexec/fastc-generate.lua" "chain dialer-proxy"
require_grep 'SRC-IP-CIDR' "$TMP/usr/libexec/fastc-generate.lua" "source network routing"
require_grep 'fastc-sync.lua' "$TMP/etc/init.d/fastc" "selector sync at startup"
require_grep 'put_select' "$TMP/usr/libexec/fastc-sync.lua" "mihomo selector API sync"
require_grep 'subnets.list' "$TMP/usr/bin/fastc-dataplane" "discovered subnet dataplane"
require_grep 'fastc_killswitch' "$TMP/usr/bin/fastc-dataplane" "FastC kill-switch"
require_grep 'sync_selectors' "$TMP/usr/bin/fastc-mode" "handoff selector verification"
require_grep 'selectors_ok' "$TMP/usr/bin/fastc-guard" "Guardian selector verification"
require_grep 'probe_node' "$TMP/usr/lib/lua/luci/controller/fastc_runtime.lua" "node exit-IP probe API"
require_grep 'probe_group' "$TMP/usr/lib/lua/luci/controller/fastc_runtime.lua" "wireless-group exit-IP probe API"
require_grep 'fastc_topology_api' "$TMP/usr/lib/lua/luci/controller/fastc_topology.lua" "topology LuCI API"
require_grep '自动发现无线' "$TMP/usr/lib/lua/luci/view/fastc/console.htm" "dynamic wireless UI"

for f in "$TMP/usr/bin/fastc-core" "$TMP/usr/bin/fastc-dataplane" "$TMP/usr/bin/fastc-mode" "$TMP/usr/bin/fastc-guard"; do
  sh -n "$f" || { echo "[ERROR] shell syntax: $f" >&2; exit 1; }
done
echo "[OK] shell syntax validated"
for f in "$TMP/usr/lib/lua/luci/controller/fastc.lua" "$TMP/usr/lib/lua/luci/controller/fastc_runtime.lua" "$TMP/usr/lib/lua/luci/controller/fastc_topology.lua" "$TMP/usr/libexec/fastc-generate.lua" "$TMP/usr/libexec/fastc-discover.lua" "$TMP/usr/libexec/fastc-sync.lua"; do
  lua_check "$f" "$f"
done
echo "[OK] 0.1.7 components validated"

for f in $FILES; do mkdir -p "/$(dirname "$f")"; cp -af "$TMP/$f" "/$f"; done
chmod 0755 /usr/bin/fastc-core /usr/bin/fastc-dataplane /usr/bin/fastc-mode /usr/bin/fastc-guard /etc/init.d/fastc /usr/libexec/fastc-import.lua /usr/libexec/fastc-generate.lua /usr/libexec/fastc-discover.lua /usr/libexec/fastc-sync.lua
chmod 0644 /etc/config/fastc /usr/lib/lua/luci/controller/fastc.lua /usr/lib/lua/luci/controller/fastc_runtime.lua /usr/lib/lua/luci/controller/fastc_topology.lua /usr/lib/lua/luci/view/fastc/console.htm /usr/share/rpcd/acl.d/fastc.json

[ -f /etc/fastc/nodes.json ] || echo '[]' > /etc/fastc/nodes.json
[ -f /etc/fastc/groups.json ] || echo '{}' > /etc/fastc/groups.json
uci set fastc.main.version='0.1.7-dev'
uci set fastc.main.mode="$OLD_MODE"
uci set fastc.main.enabled="$OLD_ENABLED"
uci set fastc.main.probe_port_base='18100'
uci set fastc.main.node_probe_port_base='18200'
uci set fastc.main.topology_path='/etc/fastc/topology.json'
uci commit fastc

lua /usr/libexec/fastc-discover.lua >/tmp/fastc-install-topology.json 2>/tmp/fastc-install-topology.log || true
[ -s /etc/fastc/topology.json ] || { echo "[ERROR] no wireless topology discovered"; cat /tmp/fastc-install-topology.log 2>/dev/null || true; exit 1; }
echo "[OK] wireless topology discovered"
cat /tmp/fastc-install-topology.json 2>/dev/null || true

[ -x /usr/bin/mihomo ] || /usr/bin/fastc-core install || true
lua /usr/libexec/fastc-generate.lua >/tmp/fastc-generate.json 2>/tmp/fastc-generate.log || { echo "[ERROR] FastC config generation failed"; cat /tmp/fastc-generate.log; exit 1; }
echo "[OK] FastC mihomo config generated from discovered topology"
/usr/bin/mihomo -t -d /etc/fastc -f /etc/fastc/config.yaml >/tmp/fastc-mihomo-check.log 2>&1 || { echo "[ERROR] mihomo config validation failed"; cat /tmp/fastc-mihomo-check.log; exit 1; }
echo "[OK] mihomo config validation passed"
/etc/init.d/fastc enable >/dev/null 2>&1 || true

FINAL_MODE="$OLD_MODE"
if [ "$OLD_MODE" = "fastc" ]; then
  echo "[INFO] Previous mode was FastC; performing topology/selector re-handoff..."
  if /usr/bin/fastc-mode fastc; then
    echo "[OK] FastC 0.1.7 strict handoff restored"
    FINAL_MODE="fastc"
  else
    echo "[WARN] FastC handoff failed; rollback to FastACL was requested"
    FINAL_MODE="$(uci -q get fastc.main.mode 2>/dev/null || echo fastacl)"
  fi
else
  /etc/init.d/fastc restart >/tmp/fastc-install-start.log 2>&1 || true
  sleep 2
fi

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] FastC 0.1.7-dev installed"
echo "[OK] UI now shows only discovered wireless/network slots and real SSID names"
echo "[OK] mihomo selector state is synchronized and guarded"
echo "[OK] exit-IP probe tries HTTP first, then HTTPS fallback"
echo "[OK] node/group database preserved"
echo "[INFO] Final traffic mode: $FINAL_MODE"
echo "[INFO] Backup: $BACKUP"
