#!/bin/sh
set -eu
PIN="116292e634274d81502d752d83c330c99f1393f5"
BASE="https://cdn.jsdelivr.net/gh/wangjontao/Actions-OpenWrt@$PIN/profiles/fastc-v010/root"
TMP="/tmp/fastc018-$$"
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
echo " FastC 0.1.8-dev Installer"
echo " lightweight node pool + shared probe listener"
echo " paged UI + visible switch feedback + faster probe"
echo "=================================================="
mkdir -p "$TMP" "$BACKUP" /etc/fastc

FILES="etc/config/fastc usr/bin/fastc-core usr/bin/fastc-dataplane usr/bin/fastc-mode usr/bin/fastc-guard etc/init.d/fastc usr/lib/lua/luci/controller/fastc.lua usr/lib/lua/luci/controller/fastc_runtime.lua usr/lib/lua/luci/controller/fastc_topology.lua usr/lib/lua/luci/view/fastc/console.htm usr/lib/lua/luci/view/fastc/console_v018.htm usr/libexec/fastc-import.lua usr/libexec/fastc-generate.lua usr/libexec/fastc-discover.lua usr/libexec/fastc-sync.lua usr/share/rpcd/acl.d/fastc.json"
for f in $FILES; do
  [ -f "/$f" ] && { mkdir -p "$BACKUP/$(dirname "$f")"; cp -af "/$f" "$BACKUP/$f"; } || true
  get "$f" "$TMP/$f"
  [ -s "$TMP/$f" ] || { echo "[ERROR] empty component: $f" >&2; exit 1; }
  echo "[OK] downloaded: $f"
done

echo "[INFO] validating FastC 0.1.8 components..."
require_grep "option version '0.1.8-dev'" "$TMP/etc/config/fastc" "version 0.1.8-dev"
require_grep "option guard_interval '15'" "$TMP/etc/config/fastc" "lower Guardian polling overhead"
require_grep 'alloc_id' "$TMP/usr/libexec/fastc-import.lua" "O(N) bulk import allocator"
require_grep 'FASTC-NODE-PROBE' "$TMP/usr/libexec/fastc-generate.lua" "shared node probe selector"
require_grep 'fastc-node-probe' "$TMP/usr/libexec/fastc-generate.lua" "single shared node probe listener"
require_grep 'log-level: warning' "$TMP/usr/libexec/fastc-generate.lua" "lower mihomo log overhead"
require_grep 'now~=wanted' "$TMP/usr/libexec/fastc-sync.lua" "selector write only on mismatch"
require_grep 'quick_node_probe' "$TMP/usr/lib/lua/luci/controller/fastc_runtime.lua" "parallel short node probe"
require_grep '检测本页' "$TMP/usr/lib/lua/luci/view/fastc/console_v018.htm" "paged node testing"
require_grep 'fc_toast' "$TMP/usr/lib/lua/luci/view/fastc/console_v018.htm" "visible operation toast"
require_grep 'renderChainList' "$TMP/usr/lib/lua/luci/view/fastc/console_v018.htm" "lazy chain selector"
require_grep 'topology.json' "$TMP/usr/libexec/fastc-discover.lua" "wireless topology database"
require_grep 'subnets.list' "$TMP/usr/bin/fastc-dataplane" "discovered subnet dataplane"
require_grep 'fastc_killswitch' "$TMP/usr/bin/fastc-dataplane" "FastC kill-switch"

for f in "$TMP/usr/bin/fastc-core" "$TMP/usr/bin/fastc-dataplane" "$TMP/usr/bin/fastc-mode" "$TMP/usr/bin/fastc-guard"; do
  sh -n "$f" || { echo "[ERROR] shell syntax: $f" >&2; exit 1; }
done
echo "[OK] shell syntax validated"
for f in "$TMP/usr/lib/lua/luci/controller/fastc.lua" "$TMP/usr/lib/lua/luci/controller/fastc_runtime.lua" "$TMP/usr/lib/lua/luci/controller/fastc_topology.lua" "$TMP/usr/libexec/fastc-generate.lua" "$TMP/usr/libexec/fastc-discover.lua" "$TMP/usr/libexec/fastc-sync.lua" "$TMP/usr/libexec/fastc-import.lua"; do
  lua_check "$f" "$f"
done
echo "[OK] 0.1.8 components validated"

for f in $FILES; do mkdir -p "/$(dirname "$f")"; cp -af "$TMP/$f" "/$f"; done
chmod 0755 /usr/bin/fastc-core /usr/bin/fastc-dataplane /usr/bin/fastc-mode /usr/bin/fastc-guard /etc/init.d/fastc /usr/libexec/fastc-import.lua /usr/libexec/fastc-generate.lua /usr/libexec/fastc-discover.lua /usr/libexec/fastc-sync.lua
chmod 0644 /etc/config/fastc /usr/lib/lua/luci/controller/fastc.lua /usr/lib/lua/luci/controller/fastc_runtime.lua /usr/lib/lua/luci/controller/fastc_topology.lua /usr/lib/lua/luci/view/fastc/console.htm /usr/lib/lua/luci/view/fastc/console_v018.htm /usr/share/rpcd/acl.d/fastc.json

# Switch LuCI to the 0.1.8 low-overhead paged console without duplicating routes.
sed -i 's/template("fastc\/console")/template("fastc\/console_v018")/' /usr/lib/lua/luci/controller/fastc.lua

[ -f /etc/fastc/nodes.json ] || echo '[]' > /etc/fastc/nodes.json
[ -f /etc/fastc/groups.json ] || echo '{}' > /etc/fastc/groups.json
uci set fastc.main.version='0.1.8-dev'
uci set fastc.main.mode="$OLD_MODE"
uci set fastc.main.enabled="$OLD_ENABLED"
uci set fastc.main.probe_port_base='18100'
uci set fastc.main.node_probe_port='18200'
uci set fastc.main.node_probe_port_base='18200'
uci set fastc.main.guard_interval='15'
uci set fastc.main.topology_path='/etc/fastc/topology.json'
uci commit fastc

lua /usr/libexec/fastc-discover.lua >/tmp/fastc-install-topology.json 2>/tmp/fastc-install-topology.log || true
[ -s /etc/fastc/topology.json ] || { echo "[ERROR] no wireless topology discovered"; cat /tmp/fastc-install-topology.log 2>/dev/null || true; exit 1; }
echo "[OK] wireless topology discovered"

[ -x /usr/bin/mihomo ] || /usr/bin/fastc-core install || true
lua /usr/libexec/fastc-generate.lua >/tmp/fastc-generate.json 2>/tmp/fastc-generate.log || { echo "[ERROR] FastC config generation failed"; cat /tmp/fastc-generate.log; exit 1; }
echo "[OK] lightweight FastC mihomo config generated"
/usr/bin/mihomo -t -d /etc/fastc -f /etc/fastc/config.yaml >/tmp/fastc-mihomo-check.log 2>&1 || { echo "[ERROR] mihomo config validation failed"; cat /tmp/fastc-mihomo-check.log; exit 1; }
echo "[OK] mihomo config validation passed"
/etc/init.d/fastc enable >/dev/null 2>&1 || true

FINAL_MODE="$OLD_MODE"
if [ "$OLD_MODE" = "fastc" ]; then
  echo "[INFO] Previous mode was FastC; restarting with shared probe listener and optimized Guardian..."
  if /usr/bin/fastc-mode fastc; then
    echo "[OK] FastC 0.1.8 strict handoff restored"
    FINAL_MODE="fastc"
  else
    echo "[WARN] FastC handoff failed; rollback to FastACL was requested"
    FINAL_MODE="$(uci -q get fastc.main.mode 2>/dev/null || echo fastacl)"
  fi
else
  /etc/init.d/fastc restart >/tmp/fastc-install-start.log 2>&1 || true
  sleep 1
fi

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] FastC 0.1.8-dev installed"
echo "[OK] bulk import allocator is O(N)"
echo "[OK] all nodes share one node-probe listener on 127.0.0.1:18200"
echo "[OK] Guardian interval reduced to 15s and selector PUT only happens on mismatch"
echo "[OK] LuCI node table is paged; chain choices load only when opened"
echo "[OK] operation feedback now uses fixed toast notifications"
echo "[OK] node delay/IP probe uses short parallel requests"
echo "[INFO] Final traffic mode: $FINAL_MODE"
echo "[INFO] Node/group database preserved"
echo "[INFO] Backup: $BACKUP"
