#!/bin/sh
set -eu

VERSION="2.3.0-stable"
APP="juliang_fastacl"
PW2="passwall2"
STATE="/etc/juliang-fastacl"
BACKUP="$STATE/backup"
RUN="/tmp/juliang-fastacl"
TMP="/tmp/jfa-stable-$$"
NODE_LIST="/usr/lib/lua/luci/view/passwall2/node_list/node_list.htm"

mkdir -p "$TMP" "$STATE" "$BACKUP" "$RUN"
trap 'rm -rf "$TMP"' EXIT INT TERM

say(){ echo "$*"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }

extract_embedded(){
  tag="$1"; dst="$2"
  awk -v b="__JFA_BEGIN_${tag}__" -v e="__JFA_END_${tag}__" '
    $0 == b { on=1; next }
    $0 == e { found=1; exit }
    on { print }
    END { if (!found) exit 2 }
  ' "$0" > "$dst"
  [ -s "$dst" ] || die "embedded payload missing: $tag"
}

need(){
  command -v "$1" >/dev/null 2>&1 || die "required command missing: $1"
}

uci_get(){
  uci -q get "$1" 2>/dev/null || true
}

set_default(){
  key="$1"; value="$2"
  [ -n "$(uci_get "$key")" ] || uci set "$key=$value"
}

backup_once(){
  src="$1"; dst="$2"
  [ -e "$src" ] || return 0
  [ -e "$dst" ] || cp -af "$src" "$dst"
}

echo "=================================================="
echo " JuLiang FastACL $VERSION"
echo " dynamic WiFi + DoH + Guardian + fail-closed"
echo "=================================================="

[ "$(id -u)" = "0" ] || die "run as root"

need uci
need nft
need ip
need curl
need sing-box
need lua
need ss

[ -x /usr/share/passwall2/app.sh ] || die "PassWall2 backend not found: /usr/share/passwall2/app.sh"
[ -f "$NODE_LIST" ] || die "PassWall2 node list not found: $NODE_LIST"
[ -f /usr/lib/lua/luci/model/uci.lua ] || die "LuCI Lua runtime not found"

# Extract and validate everything before changing the live dataplane.
extract_embedded ENGINE "$TMP/juliang-fastacl"
extract_embedded GUARD "$TMP/juliang-fastacl-guard"
extract_embedded LUCI "$TMP/juliang-fastacl-luci-install"
extract_embedded UNINSTALL "$TMP/uninstall-juliang-fastacl"
extract_embedded ROUTER "$TMP/juliang-fastacl-router.lua"
extract_embedded RELAY "$TMP/juliang-fastacl-relay.lua"
extract_embedded DISCOVER "$TMP/juliang-fastacl-discover.lua"
extract_embedded CTRL "$TMP/juliang_fastacl.lua"
extract_embedded INIT "$TMP/juliang-fastacl.init"
extract_embedded HOTPLUG "$TMP/99-juliang-fastacl"

sh -n "$TMP/juliang-fastacl"
sh -n "$TMP/juliang-fastacl-guard"
sh -n "$TMP/juliang-fastacl-luci-install"
sh -n "$TMP/uninstall-juliang-fastacl"
sh -n "$TMP/juliang-fastacl.init"
sh -n "$TMP/99-juliang-fastacl"
lua -e 'assert(loadfile("'"$TMP"'/juliang-fastacl-router.lua"))'
lua -e 'assert(loadfile("'"$TMP"'/juliang-fastacl-relay.lua"))'
lua -e 'assert(loadfile("'"$TMP"'/juliang-fastacl-discover.lua"))'
lua -e 'assert(loadfile("'"$TMP"'/juliang_fastacl.lua"))'

grep -q 'juliang_killswitch' "$TMP/juliang-fastacl" || die "embedded engine lacks kill-switch"
grep -q 'restart-ap)' "$TMP/juliang-fastacl" || die "embedded engine lacks targeted recovery"
grep -q 'switch_node "$ap" "$node" 1' "$TMP/juliang-fastacl" || die "embedded engine lacks MOVE ordering fix"
grep -q 'health_check_assigned' "$TMP/juliang-fastacl-guard" || die "embedded Guardian lacks real-exit checks"

# Save the original state once. Re-running this installer upgrades FastACL but
# does not overwrite the original rollback snapshot.
if [ ! -f "$BACKUP/original-flags" ]; then
  cat > "$BACKUP/original-flags" <<EOF
PW2_ENABLED='$(uci_get passwall2.@global[0].enabled)'
PW2_ACL_ENABLE='$(uci_get passwall2.@global[0].acl_enable)'
PW2_SOCKS_ENABLED='$(uci_get passwall2.@global[0].socks_enabled)'
EOF
fi
backup_once "$NODE_LIST" "$BACKUP/node_list.htm"
backup_once /etc/config/juliang_fastacl "$BACKUP/juliang_fastacl.pre-stable"

stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo current)"
snap="$STATE/upgrade-$stamp"
mkdir -p "$snap"
for f in   /usr/bin/juliang-fastacl   /usr/bin/juliang-fastacl-guard   /usr/bin/juliang-fastacl-luci-install   /usr/bin/uninstall-juliang-fastacl   /usr/libexec/juliang-fastacl-router.lua   /usr/libexec/juliang-fastacl-relay.lua   /usr/libexec/juliang-fastacl-discover.lua   /usr/lib/lua/luci/controller/juliang_fastacl.lua   /etc/init.d/juliang-fastacl   /etc/hotplug.d/iface/99-juliang-fastacl
do
  [ -e "$f" ] && cp -af "$f" "$snap/" 2>/dev/null || true
done

# Patch the PassWall2 UI first. On failure restore the original page and stop
# before changing firewall/runtime ownership.
say "[1/8] installing FastACL into PassWall2 node list..."
JFA_CTRL_FILE="$TMP/juliang_fastacl.lua" sh "$TMP/juliang-fastacl-luci-install" >/tmp/jfa-stable-luci.log 2>&1 || {
  cat /tmp/jfa-stable-luci.log 2>/dev/null || true
  [ -f "$BACKUP/node_list.htm" ] && cp -af "$BACKUP/node_list.htm" "$NODE_LIST"
  die "PassWall2 UI patch failed; original UI restored"
}

# Install/upgrade runtime atomically enough for BusyBox/OpenWrt.
say "[2/8] installing FastACL runtime..."
mkdir -p /usr/bin /usr/libexec /usr/lib/lua/luci/controller /etc/init.d /etc/hotplug.d/iface
cp -af "$TMP/juliang-fastacl" /usr/bin/juliang-fastacl
cp -af "$TMP/juliang-fastacl-guard" /usr/bin/juliang-fastacl-guard
cp -af "$TMP/juliang-fastacl-luci-install" /usr/bin/juliang-fastacl-luci-install
cp -af "$TMP/uninstall-juliang-fastacl" /usr/bin/uninstall-juliang-fastacl
cp -af "$TMP/juliang-fastacl-router.lua" /usr/libexec/juliang-fastacl-router.lua
cp -af "$TMP/juliang-fastacl-relay.lua" /usr/libexec/juliang-fastacl-relay.lua
cp -af "$TMP/juliang-fastacl-discover.lua" /usr/libexec/juliang-fastacl-discover.lua
cp -af "$TMP/juliang_fastacl.lua" /usr/lib/lua/luci/controller/juliang_fastacl.lua
cp -af "$TMP/juliang-fastacl.init" /etc/init.d/juliang-fastacl
cp -af "$TMP/99-juliang-fastacl" /etc/hotplug.d/iface/99-juliang-fastacl
chmod 0755 /usr/bin/juliang-fastacl /usr/bin/juliang-fastacl-guard /usr/bin/juliang-fastacl-luci-install /usr/bin/uninstall-juliang-fastacl
chmod 0755 /etc/init.d/juliang-fastacl /etc/hotplug.d/iface/99-juliang-fastacl
chmod 0644 /usr/libexec/juliang-fastacl-router.lua /usr/libexec/juliang-fastacl-relay.lua /usr/libexec/juliang-fastacl-discover.lua /usr/lib/lua/luci/controller/juliang_fastacl.lua

# Preserve existing AP bindings and per-AP DNS overrides when upgrading.
say "[3/8] preparing persistent configuration..."
touch /etc/config/juliang_fastacl
uci -q get juliang_fastacl.main >/dev/null 2>&1 || uci set juliang_fastacl.main='main'
uci set juliang_fastacl.main.enabled='1'
set_default juliang_fastacl.main.tproxy_port "'12345'"
set_default juliang_fastacl.main.mark "'0x66'"
set_default juliang_fastacl.main.route_table "'100'"
set_default juliang_fastacl.main.dns_mode "'doh'"
set_default juliang_fastacl.main.dns_server "'1.1.1.1'"
set_default juliang_fastacl.main.dns_tls_server_name "'cloudflare-dns.com'"
set_default juliang_fastacl.main.dns_path "'/dns-query'"
set_default juliang_fastacl.main.health_probe_interval "'120'"
set_default juliang_fastacl.main.health_fail_threshold "'3'"
uci set juliang_fastacl.main.version="'$VERSION'"
uci commit juliang_fastacl

# Discover actual enabled AP networks. The discovery is transactional: if
# netifd/wireless is not ready it will not erase a previous known-good map.
say "[4/8] discovering actual WiFi/network topology..."
if /usr/bin/juliang-fastacl discover >"$RUN/install-discover.json" 2>"$RUN/install-discover.log"; then
  cat "$RUN/install-discover.json"
else
  cat "$RUN/install-discover.log" 2>/dev/null || true
  count="$(uci_get juliang_fastacl.main.ap_count)"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$count" -gt 0 ] || die "no eligible AP network discovered; FastACL config was preserved"
  say "[WARN] live discovery unavailable; using preserved FastACL topology ($count APs)"
fi

count="$(uci_get juliang_fastacl.main.ap_count)"
case "$count" in ''|*[!0-9]*) count=0 ;; esac
[ "$count" -gt 0 ] || die "FastACL discovered zero AP networks"
say "[OK] detected $count FastACL wireless network(s)"

# Immediately enforce fail-closed before stopping the old PassWall2 dataplane.
# We match the dynamically discovered network names, not hard-coded A1-A10.
say "[5/8] enabling fail-closed firewall protection..."
changed=0
for sec in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=forwarding$/\1/p"); do
  src="$(uci_get firewall.$sec.src)"
  dest="$(uci_get firewall.$sec.dest)"
  [ "$dest" = "wan" ] || continue
  n=1
  while [ "$n" -le "$count" ]; do
    net="$(uci_get juliang_fastacl.ap$n.network)"
    if [ -n "$net" ] && [ "$src" = "$net" ]; then
      say "  remove direct forwarding: $src -> wan"
      uci -q delete firewall.$sec
      changed=1
      break
    fi
    n=$((n+1))
  done
done
n=1
while [ "$n" -le "$count" ]; do
  net="$(uci_get juliang_fastacl.ap$n.network)"
  if [ -n "$net" ] && [ "$(uci_get firewall.$net)" = "zone" ]; then
    if [ "$(uci_get firewall.$net.forward)" != "REJECT" ]; then
      uci set firewall.$net.forward='REJECT'
      changed=1
    fi
  fi
  n=$((n+1))
done
if [ "$changed" -ne 0 ]; then
  uci commit firewall
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
fi

# PassWall2 stays installed and keeps all nodes/subscriptions/UI, but FastACL
# owns transparent traffic. Do not let the PassWall2 S99 service kill jfa_apN.
say "[6/8] handing transparent dataplane to FastACL..."
if uci -q get passwall2.@global[0] >/dev/null 2>&1; then
  uci -q set passwall2.@global[0].enabled='0'
  uci -q set passwall2.@global[0].acl_enable='0'
  uci -q set passwall2.@global[0].socks_enabled='0'
  uci commit passwall2
fi
/etc/init.d/passwall2 stop >/dev/null 2>&1 || true
/etc/init.d/passwall2 disable >/dev/null 2>&1 || true

# If the older realtime-IP suite is already installed, upgrade only its ACL
# display components: unlimited detected ACL count and auto-hide in FastACL mode.
say "[7/8] updating optional ACL realtime-IP compatibility..."
extract_embedded PW2_ACL_JSON "$TMP/pw2-acl-ip-json"
extract_embedded PW_ACL_JSON "$TMP/pw-acl-ip-json"
extract_embedded PW2_ACL_VIEW "$TMP/pw2-acl-view.htm"
extract_embedded PW_ACL_VIEW "$TMP/pw-acl-view.htm"
extract_embedded PW2_ACL_REFRESH "$TMP/pw2-acl-refresh.htm"
extract_embedded PW_ACL_REFRESH "$TMP/pw-acl-refresh.htm"

[ -e /usr/bin/pw2-acl-ip-json ] && { cp -af "$TMP/pw2-acl-ip-json" /usr/bin/pw2-acl-ip-json; chmod 0755 /usr/bin/pw2-acl-ip-json; }
[ -e /usr/bin/pw-acl-ip-json ] && { cp -af "$TMP/pw-acl-ip-json" /usr/bin/pw-acl-ip-json; chmod 0755 /usr/bin/pw-acl-ip-json; }
[ -e /usr/lib/lua/luci/view/passwall2/acl_exit_ip_status.htm ] && cp -af "$TMP/pw2-acl-view.htm" /usr/lib/lua/luci/view/passwall2/acl_exit_ip_status.htm
[ -e /usr/lib/lua/luci/view/passwall/acl_exit_ip_status.htm ] && cp -af "$TMP/pw-acl-view.htm" /usr/lib/lua/luci/view/passwall/acl_exit_ip_status.htm
[ -e /usr/lib/lua/luci/view/passwall2/acl_ip_refresh.htm ] && cp -af "$TMP/pw2-acl-refresh.htm" /usr/lib/lua/luci/view/passwall2/acl_ip_refresh.htm
[ -e /usr/lib/lua/luci/view/passwall/acl_ip_refresh.htm ] && cp -af "$TMP/pw-acl-refresh.htm" /usr/lib/lua/luci/view/passwall/acl_ip_refresh.htm

# Enable procd Guardian, rebuild runtime and require the fail-closed table.
say "[8/8] starting Guardian and validating dataplane..."
/etc/init.d/juliang-fastacl disable >/dev/null 2>&1 || true
/etc/init.d/juliang-fastacl enable >/dev/null 2>&1 || true
/etc/init.d/juliang-fastacl restart >/dev/null 2>&1 || true
sleep 2

/usr/bin/juliang-fastacl repair >"$RUN/install-repair.log" 2>&1 || {
  cat "$RUN/install-repair.log" 2>/dev/null || true
  die "FastACL repair failed; fail-closed firewall remains in place"
}
/usr/bin/juliang-fastacl killswitch >"$RUN/install-killswitch.log" 2>&1 || {
  cat "$RUN/install-killswitch.log" 2>/dev/null || true
  die "kill-switch could not be loaded"
}
/usr/bin/juliang-fastacl save-state >/dev/null 2>&1 || true

rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "===== FastACL status ====="
/usr/bin/juliang-fastacl status

echo
echo "===== Guardian ====="
pgrep -af juliang-fastacl-guard 2>/dev/null || die "Guardian process not running"

echo
echo "===== policy ====="
ip rule show | grep -E '0x66|0x1' || true

echo
echo "===== fail-closed ====="
nft list table inet juliang_killswitch >/dev/null 2>&1 || die "juliang_killswitch missing"
echo "OK: juliang_killswitch loaded"

echo
echo "===== direct FastACL-WAN forwarding ====="
bad=0
for sec in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=forwarding$/\1/p"); do
  src="$(uci_get firewall.$sec.src)"
  dest="$(uci_get firewall.$sec.dest)"
  [ "$dest" = "wan" ] || continue
  n=1
  while [ "$n" -le "$count" ]; do
    net="$(uci_get juliang_fastacl.ap$n.network)"
    if [ -n "$net" ] && [ "$src" = "$net" ]; then
      echo "UNSAFE: $src -> wan ($sec)"
      bad=1
    fi
    n=$((n+1))
  done
done
[ "$bad" -eq 0 ] || die "unsafe AP -> WAN forwarding still exists"
echo "OK: no discovered FastACL AP forwards directly to WAN"

echo
echo "===== UI ====="
grep -q 'JULIANG_FASTACL_V220' "$NODE_LIST" || die "FastACL UI marker missing"
echo "OK: PassWall2 node-list FastACL UI installed"

echo
echo "[OK] JuLiang FastACL $VERSION installed successfully"
echo "[OK] detected WiFi networks: $count"
echo "[OK] process/listener guard: every 20s"
echo "[OK] real-exit health probe: every $(uci_get juliang_fastacl.main.health_probe_interval)s"
echo "[OK] recovery threshold: $(uci_get juliang_fastacl.main.health_fail_threshold) consecutive failures"
echo "[OK] fail-closed: node/TProxy failure causes WiFi Internet loss, never direct WAN fallback"
echo "[INFO] PassWall2 remains installed for nodes/subscriptions/UI; transparent runtime is disabled."
echo "[INFO] rollback command: /usr/bin/uninstall-juliang-fastacl"
exit 0

__JFA_BEGIN_ENGINE__
#!/bin/sh
set -u
CFG="juliang_fastacl"
APP="passwall2"
STATE_DIR="/etc/juliang-fastacl"
RUN_DIR="/tmp/juliang-fastacl"
ROUTER_CFG="$STATE_DIR/router.json"
MARK_HEX="0x66"
ROUTE_TABLE="100"
mkdir -p "$STATE_DIR" "$RUN_DIR" /tmp/etc/passwall2/bin /tmp/etc/passwall2/script_func /tmp/etc/passwall2/acl /tmp/etc/passwall2/route /tmp/etc/passwall2/iface /tmp/log /tmp/lock 2>/dev/null || true
touch /tmp/etc/passwall2/var

log(){ echo "[JFA] $*"; }

save_state(){
  local dir tmp
  dir="$STATE_DIR/last-good"
  tmp="$dir/juliang_fastacl.tmp"
  mkdir -p "$dir" || return 0
  cp -af /etc/config/juliang_fastacl "$tmp" 2>/dev/null || return 0
  mv -f "$tmp" "$dir/juliang_fastacl" 2>/dev/null || true
}

restore_state(){
  local src
  src="$STATE_DIR/last-good/juliang_fastacl"
  [ -s "$src" ] || return 1
  cp -af "$src" /etc/config/juliang_fastacl || return 1
  log "restored FastACL last-good persistent config"
  return 0
}

has_tcp_listener(){
  local port="$1"
  ss -lnt 2>/dev/null | grep -q ":$port " && return 0
  netstat -lnt 2>/dev/null | grep -q ":$port " && return 0
  return 1
}

has_any_listener(){
  local port="$1"
  ss -lnt 2>/dev/null | grep -q ":$port " && return 0
  ss -lnu 2>/dev/null | grep -q ":$port " && return 0
  netstat -lnt 2>/dev/null | grep -q ":$port " && return 0
  netstat -lnu 2>/dev/null | grep -q ":$port " && return 0
  return 1
}

ap_count(){
  local c
  c="$(uci -q get $CFG.main.ap_count 2>/dev/null || echo 0)"
  case "$c" in ''|*[!0-9]*) c=0 ;; esac
  echo "$c"
}

ap_num(){
  local n
  case "$1" in
    AP[0-9]*) n="${1#AP}" ;;
    *) return 1 ;;
  esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -ge 1 ] 2>/dev/null || return 1
  [ "$(uci -q get $CFG.ap$n 2>/dev/null || true)" = "ap" ] || return 1
  echo "$n"
}

find_acl_section(){
  local n="$1" subnet
  subnet="$(uci -q get $CFG.ap$n.subnet 2>/dev/null || true)"
  [ -n "$subnet" ] || return 0
  uci -q show "$APP" | awk -F'[.=]' -v S="$subnet" '
    /\.sources=/{gsub("\047", "", $0); if ($0 ~ "=" S "$") print $2}
  ' | head -n1
}

ensure_socks_section(){
  local n="$1" node="${2:-}" sec port type
  sec="jfa_ap$n"; port="$(uci -q get $CFG.ap$n.socks_port 2>/dev/null || echo $((13100+n)))"
  type="$(uci -q get $APP.$sec 2>/dev/null || true)"
  [ "$type" = "socks" ] || { uci -q delete $APP.$sec; uci set $APP.$sec='socks'; }
  uci set $APP.$sec.enabled='0'
  uci set $APP.$sec.bind_local='1'
  uci set $APP.$sec.port="$port"
  uci set $APP.$sec.http_port='0'
  uci set $APP.$sec.log='1'
  uci set $APP.$sec.enable_autoswitch='0'
  [ -n "$node" ] && uci set $APP.$sec.node="$node" || true
}

ensure_pre_section(){
  local n="$1" node="${2:-}" sec port type
  sec="jfa_pre$n"; port="$(uci -q get $CFG.ap$n.preproxy_port 2>/dev/null || echo $((14100+n)))"
  type="$(uci -q get $APP.$sec 2>/dev/null || true)"
  [ "$type" = "socks" ] || { uci -q delete $APP.$sec >/dev/null 2>&1 || true; uci set $APP.$sec='socks'; }
  uci set $APP.$sec.enabled='0'
  uci set $APP.$sec.bind_local='1'
  uci set $APP.$sec.port="$port"
  uci set $APP.$sec.http_port='0'
  uci set $APP.$sec.log='1'
  uci set $APP.$sec.enable_autoswitch='0'
  [ -n "$node" ] && uci set $APP.$sec.node="$node" || true
}

start_preproxy(){
  local n="$1" pre="$2" sec port plog i
  sec="jfa_pre$n"; port="$(uci -q get $CFG.ap$n.preproxy_port 2>/dev/null || echo $((14100+n)))"
  [ -n "$pre" ] || return 0
  [ "$(uci -q get $APP.$pre 2>/dev/null || true)" = "nodes" ] || {
    log "AP$n 前置节点不存在: $pre"
    return 1
  }

  ensure_pre_section "$n" "$pre"
  uci commit "$APP"

  pgrep -af '/tmp/etc/passwall2/bin' 2>/dev/null | awk -v P="$sec" '$0 ~ P {print $1}' | xargs -r kill -9 >/dev/null 2>&1 || true
  pgrep -af "SOCKS_${sec}" 2>/dev/null | awk '!/pgrep/{print $1}' | xargs -r kill -9 >/dev/null 2>&1 || true

  plog="$RUN_DIR/ap$n-preproxy-switch.log"
  : > "$plog"
  # PassWall2 socks_node_switch may return non-zero when its transparent
  # runtime cache (USE_TABLES) is absent, even if the local relay was started.
  # FastACL therefore verifies the actual listening port instead of trusting
  # the helper's shell return code.
  /usr/share/passwall2/app.sh socks_node_switch flag="$sec" new_node="$pre" >"$plog" 2>&1 || true

  i=0
  while [ "$i" -lt 6 ]; do
    has_tcp_listener "$port" && return 0
    sleep 1
    i=$((i+1))
  done

  {
    echo "AP$n preproxy SOCKS port $port not ready"
    echo "preproxy=$pre"
    echo "===== switch log ====="
    cat "$plog" 2>/dev/null || true
    echo "===== passwall2 socks log ====="
    cat "/tmp/etc/passwall2/SOCKS_${sec}.log" 2>/dev/null || true
    echo "===== generated config ====="
    cat "/tmp/etc/passwall2/SOCKS_${sec}.json" 2>/dev/null || true
  } > "$RUN_DIR/ap$n-preproxy-error.log"
  log "AP$n 前置代理端口 $port 未就绪，诊断：$RUN_DIR/ap$n-preproxy-error.log"
  return 1
}

kill_ap(){
  local n="$1" sec psec pidf flag
  sec="jfa_ap$n"; psec="jfa_pre$n"
  pidf="$RUN_DIR/ap$n.pid"
  if [ -s "$pidf" ]; then kill "$(cat "$pidf")" >/dev/null 2>&1 || true; rm -f "$pidf"; fi
  for flag in "$sec" "$psec"; do
    pgrep -af '/tmp/etc/passwall2/bin' 2>/dev/null | awk -v P="$flag" '$0 ~ P {print $1}' | xargs -r kill -9 >/dev/null 2>&1 || true
    pgrep -af "SOCKS_${flag}" 2>/dev/null | awk '!/pgrep/{print $1}' | xargs -r kill -9 >/dev/null 2>&1 || true
  done
  rm -f "$RUN_DIR/ap$n-direct.json" "$RUN_DIR/ap$n-preproxy-error.log" "$RUN_DIR/ap$n-preproxy-switch.log"
}

start_ap(){
  local n="$1" landing_node type proto port chain pre preport cfg swlog i
  landing_node="$(uci -q get $CFG.ap$n.node 2>/dev/null || true)"
  [ -n "$landing_node" ] || { kill_ap "$n"; return 0; }
  [ "$(uci -q get $APP.$landing_node 2>/dev/null || true)" = "nodes" ] || { log "AP$n 节点不存在: $landing_node"; return 1; }
  ensure_socks_section "$n" "$landing_node"
  uci commit "$APP"
  kill_ap "$n"
  type="$(uci -q get $APP.$landing_node.type 2>/dev/null | tr 'A-Z' 'a-z')"
  proto="$(uci -q get $APP.$landing_node.protocol 2>/dev/null | tr 'A-Z' 'a-z')"
  [ -n "$proto" ] || proto="$type"
  port="$(uci -q get $CFG.ap$n.socks_port 2>/dev/null || echo $((13100+n)))"
  chain="$(uci -q get $APP.$landing_node.chain_proxy 2>/dev/null || true)"
  pre="$(uci -q get $APP.$landing_node.preproxy_node 2>/dev/null || true)"

  # SOCKS/HTTP landing nodes get a deterministic cross-core bridge:
  # native preproxy core (Xray or sing-box) -> local SOCKS 141xx ->
  # sing-box landing SOCKS/HTTP -> local SOCKS 131xx.
  if [ "$proto" = "socks" ] || [ "$proto" = "http" ]; then
    preport="0"
    if [ "$chain" = "1" ] && [ -n "$pre" ]; then
      start_preproxy "$n" "$pre" || return 1
      preport="$(uci -q get $CFG.ap$n.preproxy_port 2>/dev/null || echo $((14100+n)))"
    fi
    cfg="$RUN_DIR/ap$n-direct.json"
    lua /usr/libexec/juliang-fastacl-relay.lua "$landing_node" "$port" "$cfg" "$preport" || return 1
    sing-box check -c "$cfg" >"$RUN_DIR/ap$n-relay-check.log" 2>&1 || {
      log "AP$n SOCKS/HTTP 桥接配置检查失败"
      return 1
    }
    sing-box run -c "$cfg" >"$RUN_DIR/ap$n.log" 2>&1 &
    echo $! > "$RUN_DIR/ap$n.pid"
  else
    swlog="$RUN_DIR/ap$n-switch.log"
    : > "$swlog"
    # The helper can return 1 after PassWall2 handover simply because its
    # USE_TABLES cache is empty. Do not fail on the return code; the local
    # SOCKS listener below is the authoritative health check.
    /usr/share/passwall2/app.sh socks_node_switch flag="jfa_ap$n" new_node="$landing_node" >"$swlog" 2>&1 || true
  fi
  i=0
  while [ "$i" -lt 5 ]; do
    has_tcp_listener "$port" && return 0
    sleep 1; i=$((i+1))
  done
  {
    echo "AP$n local SOCKS port $port not ready"
    echo "node=$landing_node type=$type protocol=$proto chain=$chain preproxy=$pre"
    echo "===== preproxy error ====="
    cat "$RUN_DIR/ap$n-preproxy-error.log" 2>/dev/null || true
    echo "===== relay check ====="
    cat "$RUN_DIR/ap$n-relay-check.log" 2>/dev/null || true
    echo "===== switch log ====="
    cat "$RUN_DIR/ap$n-switch.log" 2>/dev/null || true
    echo "===== passwall2 socks log ====="
    cat "/tmp/etc/passwall2/SOCKS_jfa_ap$n.log" 2>/dev/null || true
    echo "===== generated config ====="
    cat "/tmp/etc/passwall2/SOCKS_jfa_ap$n.json" 2>/dev/null || true
  } > "$RUN_DIR/ap$n-start-error.log"
  log "AP$n 本地 SOCKS 端口 $port 未就绪，诊断：$RUN_DIR/ap$n-start-error.log"
  return 1
}

probe_ap(){
  local n port ip
  n="$1"
  port="$(uci -q get $CFG.ap$n.socks_port 2>/dev/null || echo $((13100+n)))"

  # Probe through the exact AP local SOCKS path. Two independent IP services
  # avoid declaring a healthy node dead because one public service is blocked.
  ip="$(curl -4 -fsS --connect-timeout 3 --max-time 6 --socks5-hostname "127.0.0.1:$port" https://api.ipify.org 2>/dev/null | tr -d '\r\n ' || true)"
  [ -n "$ip" ] || ip="$(curl -4 -fsS --connect-timeout 3 --max-time 6 --socks5-hostname "127.0.0.1:$port" https://icanhazip.com 2>/dev/null | tr -d '\r\n ' || true)"
  [ -n "$ip" ] || ip="-"
  echo "$ip"
}

write_router(){
  lua /usr/libexec/juliang-fastacl-router.lua > "$ROUTER_CFG" || return 1
  sing-box check -c "$ROUTER_CFG" >/tmp/jfa-router-check.log 2>&1 || { cat /tmp/jfa-router-check.log; return 1; }
}

remove_fw4_accept(){
  local h
  nft list chain inet fw4 input >/dev/null 2>&1 || return 0
  for h in $(nft -a list chain inet fw4 input 2>/dev/null | awk '/comment "juliang-fastacl-tproxy"/ {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}'); do
    nft delete rule inet fw4 input handle "$h" >/dev/null 2>&1 || true
  done
}

install_fw4_accept(){
  nft list chain inet fw4 input >/dev/null 2>&1 || {
    log "warning: fw4 input chain not found; cannot install TProxy input accept rule"
    return 0
  }
  remove_fw4_accept
  nft insert rule inet fw4 input meta mark $MARK_HEX counter accept comment "juliang-fastacl-tproxy" >/dev/null 2>&1 || {
    log "failed to install fw4 TProxy input accept rule"
    return 1
  }
}

ap_sources_csv(){
  local n count subnet out
  count="$(ap_count)"
  out=""
  n=1
  while [ "$n" -le "$count" ]; do
    subnet="$(uci -q get $CFG.ap$n.subnet 2>/dev/null || true)"
    if [ -n "$subnet" ]; then
      [ -n "$out" ] && out="$out, "
      out="$out$subnet"
    fi
    n=$((n+1))
  done
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

install_killswitch(){
  local AP_SOURCES
  AP_SOURCES="$(ap_sources_csv)" || { log "no AP subnets discovered for kill-switch"; return 1; }

  # Separate fail-closed table: proxied packets are diverted to local TProxy
  # in prerouting and never reach forward. If TProxy/router disappears, AP
  # traffic falls through to forward and is dropped here instead of WAN.
  nft list table inet juliang_killswitch >/dev/null 2>&1 && nft delete table inet juliang_killswitch >/dev/null 2>&1 || true
  cat > "$RUN_DIR/killswitch.nft" <<EOF
table inet juliang_killswitch {
  set ap_sources {
    type ipv4_addr
    flags interval
    elements = { $AP_SOURCES }
  }
  chain forward {
    type filter hook forward priority -1; policy accept;
    ip saddr @ap_sources counter drop
  }
}
EOF
  nft -c -f "$RUN_DIR/killswitch.nft" || return 1
  nft -f "$RUN_DIR/killswitch.nft" || return 1
}

firewall(){
  install_killswitch || return 1
  TPROXY_PORT="$(uci -q get $CFG.main.tproxy_port 2>/dev/null || echo 12345)"
  AP_SOURCES="$(ap_sources_csv)" || { log "no AP subnets discovered"; return 1; }
  nft list table inet juliang_fastacl >/dev/null 2>&1 && nft delete table inet juliang_fastacl >/dev/null 2>&1 || true
  cat > "$RUN_DIR/rules.nft" <<EOF
 table inet juliang_fastacl {
   set ap_sources {
     type ipv4_addr
     flags interval
     elements = { $AP_SOURCES }
   }
   set local_dst {
     type ipv4_addr
     flags interval
     elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 }
   }
   chain prerouting {
     type filter hook prerouting priority mangle; policy accept;
     ip saddr @ap_sources meta l4proto { tcp, udp } th dport 53 counter tproxy ip to :$TPROXY_PORT meta mark set $MARK_HEX accept
     ip saddr @ap_sources ip daddr @local_dst counter return
     ip saddr @ap_sources meta l4proto { tcp, udp } counter tproxy ip to :$TPROXY_PORT meta mark set $MARK_HEX accept
   }
 }
EOF
  nft -c -f "$RUN_DIR/rules.nft" || return 1
  nft -f "$RUN_DIR/rules.nft" || return 1
  install_fw4_accept || return 1
  ip rule del fwmark "$MARK_HEX/0xff" table "$ROUTE_TABLE" priority 10000 >/dev/null 2>&1 || true
  ip rule add fwmark "$MARK_HEX/0xff" table "$ROUTE_TABLE" priority 10000
  ip route replace local 0.0.0.0/0 dev lo table "$ROUTE_TABLE"
}

firewall_check(){
  TPROXY_PORT="$(uci -q get $CFG.main.tproxy_port 2>/dev/null || echo 12345)"
  AP_SOURCES="$(ap_sources_csv)" || { log "no AP subnets discovered"; return 1; }
  cat > "$RUN_DIR/rules-check.nft" <<EOF
 table inet juliang_fastacl_check {
   set ap_sources {
     type ipv4_addr
     flags interval
     elements = { $AP_SOURCES }
   }
   set local_dst {
     type ipv4_addr
     flags interval
     elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 }
   }
   chain prerouting {
     type filter hook prerouting priority mangle; policy accept;
     ip saddr @ap_sources meta l4proto { tcp, udp } th dport 53 counter tproxy ip to :$TPROXY_PORT meta mark set $MARK_HEX accept
     ip saddr @ap_sources ip daddr @local_dst counter return
     ip saddr @ap_sources meta l4proto { tcp, udp } counter tproxy ip to :$TPROXY_PORT meta mark set $MARK_HEX accept
   }
 }
EOF
  nft -c -f "$RUN_DIR/rules-check.nft"
}

start_router(){
  local pid i tport
  write_router || return 1
  [ -s "$RUN_DIR/router.pid" ] && kill "$(cat "$RUN_DIR/router.pid")" >/dev/null 2>&1 || true
  sing-box run -c "$ROUTER_CFG" >"$RUN_DIR/router.log" 2>&1 &
  pid=$!
  echo "$pid" > "$RUN_DIR/router.pid"
  tport="$(uci -q get $CFG.main.tproxy_port 2>/dev/null || echo 12345)"
  i=0
  while [ "$i" -lt 5 ]; do
    kill -0 "$pid" >/dev/null 2>&1 || { cat "$RUN_DIR/router.log"; return 1; }
    if has_any_listener "$tport"; then
      return 0
    fi
    sleep 1
    i=$((i+1))
  done
  log "FastACL router process exists but TProxy port $tport is not listening"
  cat "$RUN_DIR/router.log" 2>/dev/null || true
  return 1
}

stop_router(){
  if [ -s "$RUN_DIR/router.pid" ]; then kill "$(cat "$RUN_DIR/router.pid")" >/dev/null 2>&1 || true; rm -f "$RUN_DIR/router.pid"; fi
}

cleanup_old_passwall2_dataplane(){
  # FastACL keeps PassWall2 only as node DB/UI. Any old transparent proxy
  # dataplane must not intercept AP traffic before our dedicated table.
  if [ "$(uci -q get passwall2.@global[0].enabled 2>/dev/null || echo 0)" = "0" ]; then
    nft list table inet passwall2 >/dev/null 2>&1 && nft delete table inet passwall2 >/dev/null 2>&1 || true
    pgrep -af '/tmp/etc/passwall2/acl/default/global.json' 2>/dev/null | awk '!/pgrep|awk/ {print $1}' | xargs -r kill -9 >/dev/null 2>&1 || true
    for pref in $(ip rule show 2>/dev/null | awk '/fwmark 0x1/ && /lookup 100/ {gsub(":", "", $1); print $1}'); do
      ip rule del priority "$pref" >/dev/null 2>&1 || true
    done
  fi
}

router_healthy(){
  local tport pid
  tport="$(uci -q get $CFG.main.tproxy_port 2>/dev/null || echo 12345)"
  [ -s "$RUN_DIR/router.pid" ] || return 1
  pid="$(cat "$RUN_DIR/router.pid" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1
  has_any_listener "$tport"
}

dataplane_healthy(){
  nft list table inet juliang_killswitch >/dev/null 2>&1 || return 1
  router_healthy || return 1
  nft list table inet juliang_fastacl >/dev/null 2>&1 || return 1
  ip rule show 2>/dev/null | grep -q 'fwmark 0x66/0xff.*lookup 100' || return 1
  ip route show table "$ROUTE_TABLE" 2>/dev/null | grep -q '^local default dev lo' || return 1
  return 0
}

ensure_dataplane(){
  nft list table inet juliang_killswitch >/dev/null 2>&1 || {
    log "FastACL kill-switch 缺失，自动恢复..."
    install_killswitch || return 1
  }
  cleanup_old_passwall2_dataplane
  if ! router_healthy; then
    log "FastACL 主 TProxy 未运行，自动恢复..."
    start_router || return 1
  fi
  if ! nft list table inet juliang_fastacl >/dev/null 2>&1; then
    log "FastACL nftables 表缺失，自动恢复..."
    firewall || return 1
  else
    install_fw4_accept || return 1
    if ! ip rule show 2>/dev/null | grep -q 'fwmark 0x66/0xff.*lookup 100'; then
      ip rule del fwmark "$MARK_HEX/0xff" table "$ROUTE_TABLE" priority 10000 >/dev/null 2>&1 || true
      ip rule add fwmark "$MARK_HEX/0xff" table "$ROUTE_TABLE" priority 10000 || return 1
    fi
    ip route replace local 0.0.0.0/0 dev lo table "$ROUTE_TABLE" || return 1
  fi
  dataplane_healthy
}

repair_all(){
  lua /usr/libexec/juliang-fastacl-discover.lua >"$RUN_DIR/repair-discover.json" 2>"$RUN_DIR/repair-discover.log" || true
  cleanup_old_passwall2_dataplane
  start_all
}

heal_other_aps(){
  local skip="${1:-0}" count i node port failed
  count="$(ap_count)"
  failed=0
  i=1
  while [ "$i" -le "$count" ]; do
    if [ "$i" -ne "$skip" ]; then
      node="$(uci -q get $CFG.ap$i.node 2>/dev/null || true)"
      if [ -n "$node" ] && [ "$(uci -q get $APP.$node 2>/dev/null || true)" = "nodes" ]; then
        port="$(uci -q get $CFG.ap$i.socks_port 2>/dev/null || echo $((13100+i)))"
        if ! has_tcp_listener "$port"; then
          log "AP$i 已绑定但 SOCKS:$port 掉线，自动恢复..."
          if start_ap "$i"; then
            log "AP$i 已恢复"
          else
            log "AP$i 自动恢复失败"
            failed=$((failed+1))
          fi
        fi
      fi
    fi
    i=$((i+1))
  done
  [ "$failed" -eq 0 ]
}

reload_router(){
  start_router || return 1
  firewall || return 1
}

set_dns_mode(){
  local ap="$1" mode="$2" n
  n="$(ap_num "$ap")" || { echo '{"ok":false,"error":"BAD_AP"}'; return 2; }
  case "$mode" in
    doh)
      uci set $CFG.ap$n.dns_mode='doh'
      ;;
    tcp)
      uci set $CFG.ap$n.dns_mode='tcp'
      ;;
    auto)
      uci -q delete $CFG.ap$n.dns_mode
      ;;
    *)
      echo '{"ok":false,"error":"BAD_DNS_MODE"}'
      return 2
      ;;
  esac
  uci commit "$CFG"
  save_state
  if reload_router; then
    printf '{"ok":true,"ap":"AP%s","dns_mode":"%s"}\n' "$n" "$mode"
  else
    printf '{"ok":false,"ap":"AP%s","error":"ROUTER_RELOAD_FAILED"}\n' "$n"
    return 1
  fi
}

start_all(){
  local n node failed count
  failed=0
  count="$(ap_count)"
  [ "$count" -gt 0 ] || { log "no discovered APs"; return 1; }
  n=1
  while [ "$n" -le "$count" ]; do
    node="$(uci -q get $CFG.ap$n.node 2>/dev/null || true)"
    if [ -n "$node" ]; then
      if [ "$(uci -q get $APP.$node 2>/dev/null || true)" != "nodes" ]; then
        log "AP$n stale mapping cleared: node '$node' no longer exists"
        clear_ap "AP$n" >/dev/null 2>&1 || true
      else
        start_ap "$n" || failed=$((failed+1))
      fi
    else
      kill_ap "$n"
    fi
    n=$((n+1))
  done
  [ "$failed" -eq 0 ] || {
    log "$failed assigned AP relay(s) failed to start"
    return 1
  }
  cleanup_old_passwall2_dataplane
  start_router || return 1
  firewall || return 1
  save_state
}

stop_all(){
  local n count
  count="$(ap_count)"
  n=1; while [ "$n" -le "$count" ]; do kill_ap "$n"; n=$((n+1)); done
  stop_router
  nft list table inet juliang_fastacl >/dev/null 2>&1 && nft delete table inet juliang_fastacl >/dev/null 2>&1 || true
  remove_fw4_accept
  ip rule del fwmark "$MARK_HEX/0xff" table "$ROUTE_TABLE" priority 10000 >/dev/null 2>&1 || true
  ip route flush table "$ROUTE_TABLE" >/dev/null 2>&1 || true
}

switch_node(){
  ap="$1"; node="$2"; skip_heal="${3:-0}"; n="$(ap_num "$ap")" || { echo '{"ok":false,"error":"BAD_AP"}'; return 2; }
  [ "$(uci -q get $APP.$node 2>/dev/null || true)" = "nodes" ] || { echo '{"ok":false,"error":"BAD_NODE"}'; return 3; }

  old="$(uci -q get $CFG.ap$n.node 2>/dev/null || true)"
  acl="$(find_acl_section "$n")"
  old_acl_node=""
  [ -n "$acl" ] && old_acl_node="$(uci -q get $APP.$acl.node 2>/dev/null || true)"

  uci set $CFG.ap$n.node="$node"
  ensure_socks_section "$n" "$node"
  [ -n "$acl" ] && { uci set $APP.$acl.node="$node"; uci set $APP.$acl.enabled='1'; }
  uci commit "$CFG"; uci commit "$APP"

  t0="$(date +%s)"
  if start_ap "$n" && ensure_dataplane; then
    # Normal assignment heals unrelated missing relays. MOVE uses skip_heal=1
    # until old source mappings have been removed, otherwise the source relay
    # can be accidentally restarted while its old mapping still exists.
    if [ "$skip_heal" != "1" ]; then
      heal_other_aps "$n" >/dev/null 2>&1 || true
      ensure_dataplane || true
    fi
    ip="$(probe_ap "$n")"
    printf '%s\n' "$ip" > "$RUN_DIR/ap$n.ip"
    t1="$(date +%s)"; sec=$((t1-t0))
    remark="$(uci -q get $APP.$node.remarks 2>/dev/null || echo "$node")"
    save_state
    printf '{"ok":true,"ap":"AP%s","node":"%s","remark":"%s","ip":"%s","seconds":%s,"dataplane":"running"}\n' "$n" "$node" "$(echo "$remark" | sed 's/"/\\"/g')" "$ip" "$sec"
  else
    if [ -n "$old" ]; then
      uci set $CFG.ap$n.node="$old"
      ensure_socks_section "$n" "$old"
    else
      uci -q delete $CFG.ap$n.node
      uci -q delete $APP.jfa_ap$n.node
    fi
    if [ -n "$acl" ]; then
      if [ -n "$old_acl_node" ]; then uci set $APP.$acl.node="$old_acl_node"; else uci -q delete $APP.$acl.node; fi
    fi
    uci commit "$CFG"; uci commit "$APP"
    [ -n "$old" ] && start_ap "$n" >/dev/null 2>&1 || kill_ap "$n"
    printf '{"ok":false,"ap":"AP%s","node":"%s","error":"NODE_START_FAILED","rolled_back":true}\n' "$n" "$node"
    return 4
  fi
}

move_node(){
  ap="$1"; node="$2"; n="$(ap_num "$ap")" || { echo '{"ok":false,"error":"BAD_AP"}'; return 2; }
  [ "$(uci -q get $APP.$node 2>/dev/null || true)" = "nodes" ] || { echo '{"ok":false,"error":"BAD_NODE"}'; return 3; }

  sources=""
  count="$(ap_count)"
  i=1
  while [ "$i" -le "$count" ]; do
    if [ "$i" -ne "$n" ] && [ "$(uci -q get $CFG.ap$i.node 2>/dev/null || true)" = "$node" ]; then
      sources="$sources $i"
    fi
    i=$((i+1))
  done

  # Unique-binding means MOVE, not duplicate-then-delete. Stop old AP relay(s)
  # first to avoid protocol/plugin/shared-resource collisions, but keep UCI
  # mappings until the target is confirmed healthy so rollback is possible.
  for i in $sources; do
    kill_ap "$i"
  done

  if result="$(switch_node "$ap" "$node" 1)"; then
    for i in $sources; do
      uci -q delete $CFG.ap$i.node
      uci -q delete $APP.jfa_ap$i.node
      old_acl="$(find_acl_section "$i")"
      [ -n "$old_acl" ] && uci -q delete $APP.$old_acl.node
      rm -f "$RUN_DIR/ap$i.ip"
    done
    uci commit "$CFG"
    uci commit "$APP"

    # Source mappings are now gone. Kill them once more in case a stale helper
    # recreated a local listener, then heal only truly assigned unrelated APs.
    for i in $sources; do kill_ap "$i"; done
    heal_other_aps "$n" >/dev/null 2>&1 || true
    ensure_dataplane || true

    save_state
    printf '%s\n' "$result"
    return 0
  fi

  # Target failed: source UCI mappings were intentionally left intact; restart
  # them so the previous working wireless AP is restored.
  for i in $sources; do
    start_ap "$i" >/dev/null 2>&1 || true
  done
  printf '{"ok":false,"ap":"%s","node":"%s","error":"NODE_START_FAILED","rolled_back_sources":true,"diagnostic":"%s"}\n' "$ap" "$node" "$RUN_DIR/ap$n-start-error.log"
  return 4
}

restart_ap(){
  local ap n node ip
  ap="$1"
  n="$(ap_num "$ap")" || { echo '{"ok":false,"error":"BAD_AP"}'; return 2; }
  node="$(uci -q get $CFG.ap$n.node 2>/dev/null || true)"
  [ -n "$node" ] || { printf '{"ok":false,"ap":"%s","error":"UNASSIGNED"}\n' "$ap"; return 3; }
  [ "$(uci -q get $APP.$node 2>/dev/null || true)" = "nodes" ] || {
    printf '{"ok":false,"ap":"%s","error":"BAD_NODE"}\n' "$ap"
    return 4
  }

  if start_ap "$n" && ensure_dataplane; then
    ip="$(probe_ap "$n")"
    printf '%s\n' "$ip" > "$RUN_DIR/ap$n.ip"
    printf '{"ok":true,"ap":"AP%s","node":"%s","ip":"%s"}\n' "$n" "$node" "$ip"
    return 0
  fi

  printf '{"ok":false,"ap":"AP%s","node":"%s","error":"RESTART_FAILED"}\n' "$n" "$node"
  return 5
}

clear_ap(){
  ap="$1"; n="$(ap_num "$ap")" || { echo '{"ok":false,"error":"BAD_AP"}'; return 2; }
  old="$(uci -q get $CFG.ap$n.node 2>/dev/null || true)"
  uci -q delete $CFG.ap$n.node
  ensure_socks_section "$n" ""
  uci -q delete $APP.jfa_ap$n.node
  acl="$(find_acl_section "$n")"
  [ -n "$acl" ] && uci -q delete $APP.$acl.node
  uci commit "$CFG"; uci commit "$APP"
  save_state
  kill_ap "$n"
  rm -f "$RUN_DIR/ap$n.ip"
  printf '{"ok":true,"ap":"AP%s","old_node":"%s"}\n' "$n" "$old"
}

status(){
  local tport router_state count
  echo "JuLiang FastACL"
  tport="$(uci -q get $CFG.main.tproxy_port 2>/dev/null || echo 12345)"
  router_state="stopped"
  if router_healthy; then
    router_state="running"
  elif [ -s "$RUN_DIR/router.pid" ] && kill -0 "$(cat "$RUN_DIR/router.pid")" 2>/dev/null; then
    router_state="broken(no-listener:$tport)"
  fi
  echo "router: $router_state"
  nft list table inet juliang_fastacl >/dev/null 2>&1 && echo "nftables: loaded" || echo "nftables: missing"
  nft list table inet juliang_killswitch >/dev/null 2>&1 && echo "killswitch: loaded(fail-closed)" || echo "killswitch: MISSING"
  count="$(ap_count)"
  echo "wireless: $count discovered"
  n=1; while [ "$n" -le "$count" ]; do
    node="$(uci -q get $CFG.ap$n.node 2>/dev/null || true)"
    port="$(uci -q get $CFG.ap$n.socks_port 2>/dev/null || echo $((13100+n)))"
    ssid="$(uci -q get $CFG.ap$n.ssid 2>/dev/null || echo "AP$n")"
    net="$(uci -q get $CFG.ap$n.network 2>/dev/null || true)"
    subnet="$(uci -q get $CFG.ap$n.subnet 2>/dev/null || true)"
    if [ -n "$node" ]; then
      remark="$(uci -q get $APP.$node.remarks 2>/dev/null || echo "$node")"
      listen="no"; has_tcp_listener "$port" && listen="yes"
      echo "AP$n [$ssid | $net | $subnet] -> $remark | socks:$port listen:$listen"
    else
      echo "AP$n [$ssid | $net | $subnet] -> unassigned"
    fi
    n=$((n+1))
  done
}

case "${1:-}" in
  start) start_all ;;
  stop) stop_all ;;
  restart) stop_all; start_all ;;
  firewall) firewall ;;
  killswitch) install_killswitch ;;
  firewall-check) firewall_check ;;
  switch) [ $# -eq 3 ] || exit 2; switch_node "$2" "$3" ;;
  move) [ $# -eq 3 ] || exit 2; move_node "$2" "$3" ;;
  clear) [ $# -eq 2 ] || exit 2; clear_ap "$2" ;;
  restart-ap) [ $# -eq 2 ] || exit 2; restart_ap "$2" ;;
  probe) n="$(ap_num "$2")" || exit 2; probe_ap "$n" ;;
  status) status ;;
  discover) lua /usr/libexec/juliang-fastacl-discover.lua ;;
  repair) repair_all ;;
  heal) heal_other_aps 0 ;;
  ensure) ensure_dataplane ;;
  save-state) save_state ;;
  restore-state) restore_state ;;
  router-reload) reload_router ;;
  dns) [ $# -eq 3 ] || exit 2; set_dns_mode "$2" "$3" ;;
  *) echo "Usage: juliang-fastacl {start|stop|restart|repair|heal|ensure|killswitch|save-state|restore-state|router-reload|dns AP1 doh|dns AP1 tcp|dns AP1 auto|discover|firewall|firewall-check|switch AP1 nodeid|move AP1 nodeid|clear AP1|restart-ap AP1|probe AP1|status}"; exit 1 ;;
esac
__JFA_END_ENGINE__

__JFA_BEGIN_GUARD__
#!/bin/sh
set -u

LOG="/tmp/juliang-fastacl/guard.log"
mkdir -p /tmp/juliang-fastacl

log(){
  echo "$(date '+%Y-%m-%d %H:%M:%S') [GUARD] $*" >> "$LOG"
}

disable_passwall2_runtime(){
  local changed=0
  [ "$(uci -q get passwall2.@global[0].enabled 2>/dev/null || echo 0)" = "0" ] || { uci -q set passwall2.@global[0].enabled=0; changed=1; }
  [ "$(uci -q get passwall2.@global[0].acl_enable 2>/dev/null || echo 0)" = "0" ] || { uci -q set passwall2.@global[0].acl_enable=0; changed=1; }
  [ "$(uci -q get passwall2.@global[0].socks_enabled 2>/dev/null || echo 0)" = "0" ] || { uci -q set passwall2.@global[0].socks_enabled=0; changed=1; }
  [ "$changed" -eq 0 ] || uci commit passwall2
}

enforce_failclosed_firewall(){
  local sec src dest apsec net changed
  changed=0

  # Remove direct WAN forwarding for every network currently discovered by
  # FastACL. This is intentionally dynamic: 5, 10, 20 or any later AP count.
  for sec in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=forwarding$/\1/p"); do
    src="$(uci -q get firewall.$sec.src 2>/dev/null || true)"
    dest="$(uci -q get firewall.$sec.dest 2>/dev/null || true)"
    [ "$dest" = "wan" ] || continue

    for apsec in $(uci -q show juliang_fastacl | sed -n "s/^juliang_fastacl\.\([^.=]*\)=ap$/\1/p"); do
      net="$(uci -q get juliang_fastacl.$apsec.network 2>/dev/null || true)"
      if [ -n "$net" ] && [ "$src" = "$net" ]; then
        uci -q delete firewall.$sec
        changed=1
        break
      fi
    done
  done

  # Every FastACL AP firewall zone must itself remain REJECT for forwarding.
  for apsec in $(uci -q show juliang_fastacl | sed -n "s/^juliang_fastacl\.\([^.=]*\)=ap$/\1/p"); do
    net="$(uci -q get juliang_fastacl.$apsec.network 2>/dev/null || true)"
    [ -n "$net" ] || continue
    if [ "$(uci -q get firewall.$net 2>/dev/null || true)" = "zone" ] && \
       [ "$(uci -q get firewall.$net.forward 2>/dev/null || true)" != "REJECT" ]; then
      uci set firewall.$net.forward='REJECT'
      changed=1
    fi
  done

  if [ "$changed" -ne 0 ]; then
    uci commit firewall
    /etc/init.d/firewall restart >/dev/null 2>&1 || true
    log "removed unsafe FastACL AP -> WAN forwarding / restored REJECT zones"
  fi
}

health_check_assigned(){
  local count i node threshold failfile fails ip ap probedir assigned
  count="$(uci -q get juliang_fastacl.main.ap_count 2>/dev/null || echo 0)"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  threshold="$(uci -q get juliang_fastacl.main.health_fail_threshold 2>/dev/null || echo 3)"
  case "$threshold" in ''|*[!0-9]*) threshold=3 ;; esac
  [ "$threshold" -ge 1 ] || threshold=3

  # Probe assigned APs in parallel. Even with 20 WiFi networks, one slow/dead
  # upstream cannot make the Guardian wait 20x the curl timeout.
  probedir="/tmp/juliang-fastacl/health-probes"
  rm -rf "$probedir"
  mkdir -p "$probedir"
  assigned=""

  i=1
  while [ "$i" -le "$count" ]; do
    node="$(uci -q get juliang_fastacl.ap$i.node 2>/dev/null || true)"
    if [ -n "$node" ]; then
      assigned="$assigned $i"
      (/usr/bin/juliang-fastacl probe "AP$i" >"$probedir/ap$i.out" 2>/dev/null || true) &
    else
      rm -f "/tmp/juliang-fastacl/ap$i.health_fail"
    fi
    i=$((i+1))
  done
  wait

  for i in $assigned; do
    ap="AP$i"
    failfile="/tmp/juliang-fastacl/ap$i.health_fail"
    ip="$(cat "$probedir/ap$i.out" 2>/dev/null | tr -d '\r\n ' || true)"

    if [ -n "$ip" ] && [ "$ip" != "-" ]; then
      printf '%s\n' "$ip" > "/tmp/juliang-fastacl/ap$i.ip"
      rm -f "$failfile"
      continue
    fi

    fails="$(cat "$failfile" 2>/dev/null || echo 0)"
    case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
    fails=$((fails+1))
    printf '%s\n' "$fails" > "$failfile"
    log "$ap real-exit probe failed ($fails/$threshold)"

    if [ "$fails" -ge "$threshold" ]; then
      log "$ap real-exit failed $fails consecutive probes; restarting only this relay"
      if /usr/bin/juliang-fastacl restart-ap "$ap" >/tmp/juliang-fastacl/ap$i.health_restart.log 2>&1; then
        ip="$(/usr/bin/juliang-fastacl probe "$ap" 2>/dev/null | tr -d '\r\n ' || true)"
        if [ -n "$ip" ] && [ "$ip" != "-" ]; then
          printf '%s\n' "$ip" > "/tmp/juliang-fastacl/ap$i.ip"
          rm -f "$failfile"
          log "$ap real-exit recovered: $ip"
        else
          # Give the upstream another full threshold window before restarting
          # it again. Fail-closed remains active throughout.
          printf '0\n' > "$failfile"
          log "$ap relay restarted but real-exit is still unavailable; fail-closed remains active"
        fi
      else
        printf '0\n' > "$failfile"
        log "$ap targeted relay restart failed; fail-closed remains active"
      fi
    fi
  done

  rm -rf "$probedir"
}

# Real-exit health is intentionally lower frequency than process checks.
# Default: one real probe every 120 seconds; 3 consecutive failures before
# restarting only the affected AP relay.
last_health=0

# Wait for network/wireless services. Persistent UCI bindings are kept intact
# while we wait; discovery itself is transactional and cannot erase them.
sleep 12

while true; do
  if [ "$(uci -q get juliang_fastacl.main.enabled 2>/dev/null || echo 0)" != "1" ]; then
    sleep 30
    continue
  fi

  disable_passwall2_runtime
  enforce_failclosed_firewall

  # If persistent topology is unexpectedly missing, first attempt
  # discovery. If boot services are not ready yet, restore last-good state.
  count="$(uci -q get juliang_fastacl.main.ap_count 2>/dev/null || echo 0)"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -eq 0 ]; then
    if lua /usr/libexec/juliang-fastacl-discover.lua >/tmp/juliang-fastacl/guard-discover.json 2>/tmp/juliang-fastacl/guard-discover.log; then
      log "wireless topology discovered"
    elif /usr/bin/juliang-fastacl restore-state >/tmp/juliang-fastacl/guard-restore.log 2>&1; then
      log "persistent config restored from last-good snapshot"
    else
      log "wireless not ready and no last-good snapshot; retrying"
      sleep 15
      continue
    fi
  fi

  if ! /usr/bin/juliang-fastacl ensure >/tmp/juliang-fastacl/guard-ensure.log 2>&1; then
    log "dataplane unhealthy; full repair"
    if /usr/bin/juliang-fastacl repair >/tmp/juliang-fastacl/guard-repair.log 2>&1; then
      log "dataplane repaired"
    else
      log "dataplane repair failed"
    fi
  fi

  if ! /usr/bin/juliang-fastacl heal >/tmp/juliang-fastacl/guard-heal.log 2>&1; then
    log "one or more AP relays were missing; heal attempted"
  fi

  interval="$(uci -q get juliang_fastacl.main.health_probe_interval 2>/dev/null || echo 120)"
  case "$interval" in ''|*[!0-9]*) interval=120 ;; esac
  [ "$interval" -ge 60 ] || interval=60
  now="$(date +%s)"
  if [ "$last_health" -eq 0 ] || [ $((now-last_health)) -ge "$interval" ]; then
    health_check_assigned
    last_health="$now"
  fi

  sleep 20
done

__JFA_END_GUARD__

__JFA_BEGIN_LUCI__
#!/bin/sh
set -eu

FILE="${JFA_NODE_LIST_FILE:-/usr/lib/lua/luci/view/passwall2/node_list/node_list.htm}"
CTRL="${JFA_CTRL_FILE:-/usr/lib/lua/luci/controller/juliang_fastacl.lua}"
MARKER="JULIANG_FASTACL_V220"

[ -f "$FILE" ] || {
    echo "[ERROR] PassWall2 node_list.htm not found: $FILE"
    exit 1
}
[ -f "$CTRL" ] || {
    echo "[ERROR] FastACL LuCI controller not found: $CTRL"
    exit 1
}

# Remove the old Quick-ACL UI cleanly. Its backup is the original PassWall2
# node list from before the experimental v1 patch.
if [ -f "$FILE.quick-acl.bak" ]; then
    cp -af "$FILE.quick-acl.bak" "$FILE"
    echo "[INFO] restored original PassWall2 node list from Quick-ACL backup"
fi

if grep -q "$MARKER" "$FILE"; then
    echo "[OK] FastACL v2.2 LuCI already installed"
    exit 0
fi

# Upgrade safely from any previous FastACL v2 UI patch. Always repatch from
# the original PassWall2 node list backup to avoid duplicate buttons/modals.
if grep -q 'JULIANG_FASTACL_V2' "$FILE" 2>/dev/null && [ -f "$FILE.jfa-v2.bak" ]; then
    cp -af "$FILE.jfa-v2.bak" "$FILE"
    echo "[INFO] restored original PassWall2 node list before v2.2 repatch"
fi

[ -f "$FILE.jfa-v2.bak" ] || cp -a "$FILE" "$FILE.jfa-v2.bak"

FILE="$FILE" lua <<'LUA_PATCH'
local file = assert(os.getenv("FILE"))
local f = assert(io.open(file, "r"))
local text = f:read("*a")
f:close()

local function replace_once(src, needle, repl, label)
    local s, e = src:find(needle, 1, true)
    assert(s, (label or "anchor") .. " missing")
    return src:sub(1, s - 1) .. repl .. src:sub(e + 1)
end

local top_old = 'local appname = api.appname\n'
local top_new = 'local appname = api.appname\nlocal jfa_url = require("luci.dispatcher").build_url("admin", "services", "juliang_fastacl")\n'
text = replace_once(text, top_old, top_new, "top anchor")

local js_anchor = '\n\tfunction to_edit_node(cbi_id) {'
local js = [=[

    // JULIANG_FASTACL_V220
    var jfaNode = "";
    var jfaMap = {};
    var jfaLabels = {};
    var jfaIps = {};
    var jfaEngine = "unknown";
    var jfaPreproxy = {};
    var jfaAps = [];

    function jfa_label(ap) {
        return jfaLabels[ap] || ("无线" + ap);
    }

    function jfa_assignments(node) {
        return jfaMap[node] || [];
    }

    function jfa_update_buttons() {
        var buttons = document.getElementsByClassName("jfa-btn");
        for (var i = 0; i < buttons.length; i++) {
            var node = buttons[i].getAttribute("data-node-id");
            var aps = jfa_assignments(node);
            var labels = [];
            var ips = [];

            for (var j = 0; j < aps.length; j++) {
                labels.push(jfa_label(aps[j]));
                if (jfaIps[aps[j]])
                    ips.push(jfaIps[aps[j]]);
            }

            buttons[i].value = labels.length ? labels.join(",") : "分配无线";
            buttons[i].title = labels.length
                ? ("FastACL 已绑定：" + labels.join(", ") + (ips.length ? "\n出口 IP：" + ips.join(", ") : ""))
                : "FastACL：点击即时分配到无线 AP";

            var ipNode = document.getElementById("jfa_ip_" + node);
            if (ipNode) {
                ipNode.textContent = ips.join(" / ");
                ipNode.style.display = ips.length ? "inline-block" : "none";
            }
        }
    }

    function jfa_refresh_select() {
        var sel = document.getElementById("jfa_select");
        if (!sel) return;

        var keep = sel.value || "";
        while (sel.options.length) sel.remove(0);

        var head = document.createElement("option");
        head.value = "";
        head.text = "请选择无线";
        sel.add(head);

        for (var i = 0; i < jfaAps.length; i++) {
            var a = jfaAps[i];
            var o = document.createElement("option");
            o.value = a.ap;
            var name = a.ssid || a.ap;
            var net = a.network ? (" · " + a.network) : "";
            var subnet = a.subnet ? (" · " + a.subnet) : "";
            o.text = name + net + subnet;
            sel.add(o);
        }

        if (keep) sel.value = keep;
    }

    function jfa_load_status(done) {
        XHR.get('<%=jfa_url%>', { action: 'status' }, function(x, result) {
            if (x && x.status == 200 && result && result.ok) {
                jfaMap = result.map || {};
                jfaLabels = result.wireless_labels || {};
                jfaIps = result.ips || {};
                jfaEngine = result.engine || "unknown";
                jfaPreproxy = result.preproxy || {};
                jfaAps = result.aps || [];
                jfa_refresh_select();
                jfa_update_buttons();
            }
            if (done) done(result || {});
        });
    }

    function jfa_preproxy_current(node) {
        var p = jfaPreproxy[node] || {};
        return (p.enabled && p.remarks) ? p.remarks : "不使用";
    }

    function jfa_load_preproxy_options(node, done) {
        XHR.get('<%=jfa_url%>', {
            action: 'preproxy_options',
            node: node
        }, function(x, result) {
            var sel = document.getElementById("jfa_preproxy_select");
            if (sel) {
                while (sel.options.length) sel.remove(0);
                var o0 = document.createElement("option");
                o0.value = "";
                o0.text = "不使用前置代理（直连落地）";
                sel.add(o0);

                if (x && x.status == 200 && result && result.ok) {
                    var opts = result.options || [];
                    for (var i = 0; i < opts.length; i++) {
                        var o = document.createElement("option");
                        o.value = opts[i].id;
                        var core = opts[i].type || "";
                        var proto = opts[i].protocol || "";
                        var suffix = "";
                        if (core || proto)
                            suffix = " · " + core + (proto && proto.toLowerCase() != core.toLowerCase() ? ("/" + proto) : "");
                        o.text = opts[i].remarks + suffix;
                        sel.add(o);
                    }
                    sel.value = result.enabled ? (result.current || "") : "";
                }
            }
            if (done) done(result || {});
        });
    }

    function jfa_apply_preproxy() {
        if (!jfaNode) return;

        var sel = document.getElementById("jfa_preproxy_select");
        var pre = sel ? sel.value : "";
        var status = document.getElementById("jfa_preproxy_status");
        status.innerText = pre ? "正在切换前置代理…" : "正在关闭前置代理…";
        status.style.color = "#606266";

        XHR.get('<%=jfa_url%>', {
            action: 'set_preproxy',
            node: jfaNode,
            preproxy: pre
        }, function(x, result) {
            if (x && x.status == 200 && result && result.ok) {
                var msg = pre ? ("✓ 前置已切换：" + (result.preproxy_remarks || pre)) : "✓ 已关闭前置代理";
                if (result.affected && result.affected.length)
                    msg += "；即时刷新 " + result.affected.join(",");
                if (result.ip && result.ip != "-")
                    msg += "；出口 IP " + result.ip;
                status.innerText = msg;
                status.style.color = "#159957";
                jfa_load_status(function() {
                    document.getElementById("jfa_preproxy_current").innerText = jfa_preproxy_current(jfaNode);
                });
            } else {
                status.innerText = "前置切换失败：" + ((result && result.error) || "ERROR");
                status.style.color = "#e43f3b";
            }
        });
    }

    function jfa_open(cbi_id) {
        jfaNode = cbi_id;
        var remarks = (document.getElementById("cbid.<%=appname%>." + cbi_id + ".remarks") || {}).value || cbi_id;
        document.getElementById("jfa_node_name").innerText = remarks;
        document.getElementById("jfa_div").style.display = "block";
        document.getElementById("jfa_status").innerText = "";

        jfa_load_status(function() {
            var aps = jfa_assignments(cbi_id);
            var labels = [];
            for (var i = 0; i < aps.length; i++) labels.push(jfa_label(aps[i]));

            document.getElementById("jfa_current").innerText = labels.length ? labels.join(", ") : "未分配";
            document.getElementById("jfa_engine").innerText =
                jfaEngine == "running" ? "FastACL：运行中" : "FastACL：未运行";
            document.getElementById("jfa_engine").style.color =
                jfaEngine == "running" ? "#159957" : "#e43f3b";
            document.getElementById("jfa_preproxy_current").innerText = jfa_preproxy_current(cbi_id);
            document.getElementById("jfa_preproxy_status").innerText = "";
            jfa_load_preproxy_options(cbi_id);

            if (aps.length && /^AP[0-9]+$/.test(aps[0]))
                document.getElementById("jfa_select").value = aps[0];
        });
    }

    function jfa_close() {
        document.getElementById("jfa_div").style.display = "none";
        jfaNode = "";
    }

    function jfa_assign() {
        if (!jfaNode) return;

        var ap = document.getElementById("jfa_select").value;
        if (!ap) {
            alert("请选择无线 AP");
            return;
        }

        var exclusive = document.getElementById("jfa_exclusive").checked ? "1" : "0";
        var status = document.getElementById("jfa_status");
        status.innerText = "正在即时切换 " + jfa_label(ap) + "…";

        XHR.get('<%=jfa_url%>', {
            action: 'assign',
            node: jfaNode,
            ap: ap,
            exclusive: exclusive
        }, function(x, result) {
            if (x && x.status == 200 && result && result.ok) {
                var msg = "✓ " + jfa_label(ap) + " 已切换";
                if (result.ip && result.ip != "-")
                    msg += "；出口 IP " + result.ip;
                if (result.seconds != null)
                    msg += "；耗时 " + result.seconds + "s";
                status.innerText = msg;
                status.style.color = "#159957";

                jfa_load_status(function() {
                    var aps = jfa_assignments(jfaNode);
                    var labels = [];
                    for (var i = 0; i < aps.length; i++) labels.push(jfa_label(aps[i]));
                    document.getElementById("jfa_current").innerText = labels.length ? labels.join(", ") : "未分配";
                });
            } else {
                status.innerText = "切换失败：" + ((result && result.error) || "ERROR");
                status.style.color = "#e43f3b";
            }
        });
    }

    function jfa_clear() {
        if (!jfaNode) return;
        if (!confirm("解除这个节点当前绑定的无线 AP？")) return;

        var status = document.getElementById("jfa_status");
        status.innerText = "正在解除…";

        XHR.get('<%=jfa_url%>', {
            action: 'clear_node',
            node: jfaNode
        }, function(x, result) {
            if (x && x.status == 200 && result && result.ok) {
                status.innerText = "✓ 已解除绑定";
                status.style.color = "#159957";
                jfa_load_status(function() {
                    document.getElementById("jfa_current").innerText = "未分配";
                });
            } else {
                status.innerText = "解除失败：" + ((result && result.error) || "ERROR");
                status.style.color = "#e43f3b";
            }
        });
    }
]=]
text = replace_once(text, js_anchor, js .. js_anchor, "JS anchor")

local copy_anchor = '\n\t\t\t\t<input class="btn cbi-button cbi-button-add" type="button" value="<%:Copy%>" onclick="copy_node(\'{{id}}\')"/>'
local button = [=[
				<input class="btn cbi-button cbi-button-edit jfa-btn" type="button" id="jfa_{{id}}" data-node-id="{{id}}" value="分配无线" onclick="jfa_open('{{id}}')" title="FastACL 即时分配无线"/>
				<span id="jfa_ip_{{id}}" style="display:none;margin-left:5px;color:#159957;font-weight:600;font-size:12px;white-space:nowrap;"></span>
]=]
text = replace_once(text, copy_anchor, "\n" .. button .. copy_anchor, "button anchor")

local ping_call = '\n\t\t\tpingAllNodes();'
text = replace_once(text, ping_call, ping_call .. '\n\t\t\tjfa_load_status();', "load-status anchor")

local modal = [=[

<div id="jfa_div" style="display:none;width:35rem;max-width:94vw;position:fixed;left:50%;top:50%;transform:translate(-50%,-50%);z-index:220;padding:22px;text-align:center;background:var(--main-bg-color,#fff);border-radius:12px;box-shadow:0 12px 42px rgba(0,0,0,.38);">
    <div style="font-size:17px;font-weight:700;margin-bottom:7px;">FastACL 即时分配无线</div>
    <div style="font-size:12px;opacity:.72;margin-bottom:13px;">自动读取 SSID / network / IPv4 网段 · 不重启系统 DNS · 只切换当前无线</div>
    <div style="margin:7px 0;">节点：<strong id="jfa_node_name" style="color:#159957"></strong></div>
    <div style="margin:7px 0;">当前：<strong id="jfa_current" style="color:#e6a23c">读取中…</strong></div>
    <div id="jfa_engine" style="margin:7px 0;font-weight:600;">FastACL：检测中…</div>
    <div style="margin:13px 0;">
        <select id="jfa_select" class="cbi-input-select" style="min-width:300px;">
            <option value="">自动读取中…</option>
        </select>
    </div>
    <div style="margin:16px 0 8px;padding:12px;border-top:1px solid rgba(128,128,128,.22);">
        <div style="font-weight:700;margin-bottom:8px;">快速前置代理</div>
        <div style="font-size:12px;opacity:.72;margin-bottom:9px;">支持跨内核：Xray/VLESS 前置 → sing-box/SOCKS5 落地；只切当前 AP，本地桥接端口 141xx</div>
        <div style="margin:6px 0;">当前前置：<strong id="jfa_preproxy_current" style="color:#e6a23c">读取中…</strong></div>
        <div style="display:flex;justify-content:center;gap:8px;flex-wrap:wrap;align-items:center;">
            <select id="jfa_preproxy_select" class="cbi-input-select" style="min-width:260px;">
                <option value="">不使用前置代理（直连落地）</option>
            </select>
            <input class="btn cbi-button cbi-button-apply" type="button" value="应用前置" onclick="jfa_apply_preproxy()"/>
        </div>
        <div id="jfa_preproxy_status" style="min-height:22px;margin-top:8px;font-weight:600;"></div>
    </div>
    <label style="display:block;margin:10px 0;">
        <input id="jfa_exclusive" type="checkbox" checked="checked"/>
        唯一绑定：同一个节点只分配给一个无线 AP
    </label>
    <div id="jfa_status" style="min-height:24px;margin:9px 0;font-weight:600;color:#159957;"></div>
    <div style="display:flex;justify-content:center;gap:8px;flex-wrap:wrap;">
        <input class="btn cbi-button cbi-button-apply" type="button" value="立即切换" onclick="jfa_assign()"/>
        <input class="btn cbi-button cbi-button-remove" type="button" value="解除绑定" onclick="jfa_clear()"/>
        <input class="btn cbi-button cbi-button-edit" type="button" value="关闭" onclick="jfa_close()"/>
    </div>
</div>
]=]

text = text .. modal

local out = assert(io.open(file .. ".new", "w"))
out:write(text)
out:close()
os.rename(file .. ".new", file)
LUA_PATCH

grep -q "$MARKER" "$FILE"
grep -q 'jfa-btn' "$FILE"
grep -q 'FastACL 即时分配无线' "$FILE"
grep -q '快速前置代理' "$FILE"

if [ "${JFA_OFFLINE:-0}" != "1" ]; then
    rm -f /tmp/luci-indexcache
    rm -rf /tmp/luci-modulecache /tmp/luci-templatecache
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
fi

echo "[OK] FastACL v2 LuCI installed"
echo "PassWall2 -> 节点列表：自动读取真实无线/网段 + 即时分配 + 跨内核快速前置，并显示出口 IP。"

__JFA_END_LUCI__

__JFA_BEGIN_UNINSTALL__
#!/bin/sh
set -u

BACKUP_DIR="/etc/juliang-fastacl/backup"
NODE_LIST="/usr/lib/lua/luci/view/passwall2/node_list/node_list.htm"

echo "=================================================="
echo " JuLiang FastACL v2 rollback"
echo "=================================================="

/etc/init.d/juliang-fastacl stop >/dev/null 2>&1 || true
/etc/init.d/juliang-fastacl disable >/dev/null 2>&1 || true

# FastACL stop intentionally leaves the independent kill-switch fail-closed.
# A deliberate uninstall must remove it before restoring PassWall2.
nft list table inet juliang_killswitch >/dev/null 2>&1 && nft delete table inet juliang_killswitch >/dev/null 2>&1 || true

# Keep all current PassWall2 nodes and the AP mappings FastACL mirrored into
# the original ACL sections. Only remove our shadow SOCKS holders and restore
# the three original engine switches.
n=1
while [ "$n" -le 64 ]; do
    uci -q delete passwall2.jfa_ap$n
    uci -q delete passwall2.jfa_pre$n
    n=$((n + 1))
done

if [ -f "$BACKUP_DIR/original-flags" ]; then
    . "$BACKUP_DIR/original-flags"
    uci -q set passwall2.@global[0].enabled="${PW2_ENABLED:-0}"
    uci -q set passwall2.@global[0].acl_enable="${PW2_ACL_ENABLE:-1}"
    uci -q set passwall2.@global[0].socks_enabled="${PW2_SOCKS_ENABLED:-0}"
fi
uci -q commit passwall2

if [ -f "$BACKUP_DIR/node_list.htm" ]; then
    cp -af "$BACKUP_DIR/node_list.htm" "$NODE_LIST"
    echo "[OK] restored PassWall2 node list UI"
fi

rm -f /etc/config/juliang_fastacl
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache
rm -rf /tmp/juliang-fastacl

/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
if [ "${PW2_ENABLED:-0}" = "1" ]; then
    /etc/init.d/passwall2 enable >/dev/null 2>&1 || true
    /etc/init.d/passwall2 restart >/tmp/passwall2-fastacl-rollback.log 2>&1 &
else
    /etc/init.d/passwall2 disable >/dev/null 2>&1 || true
fi

echo "[OK] FastACL disabled; current nodes/AP mappings kept"
echo "PassWall2 is restoring in background; log: /tmp/passwall2-fastacl-rollback.log"

__JFA_END_UNINSTALL__

__JFA_BEGIN_ROUTER__
local jsonc = require "luci.jsonc"
local uci = require("luci.model.uci").cursor()
local cfg = "juliang_fastacl"
local port = tonumber(uci:get(cfg, "main", "tproxy_port") or "12345")
local dns_mode = uci:get(cfg, "main", "dns_mode") or "doh"
local dns_addr = uci:get(cfg, "main", "dns_server") or "1.1.1.1"
local dns_tls_name = uci:get(cfg, "main", "dns_tls_server_name") or "cloudflare-dns.com"
local dns_path = uci:get(cfg, "main", "dns_path") or "/dns-query"

local aps = {}
uci:foreach(cfg, "ap", function(s)
  local slot = tonumber(s.slot or (s[".name"] or ""):match("^ap(%d+)$"))
  local subnet = s.subnet
  local sport = tonumber(s.socks_port)
  if slot and subnet and subnet ~= "" and sport then
    aps[#aps + 1] = {
      slot = slot,
      subnet = subnet,
      sport = sport,
      name = s[".name"] or ("ap" .. slot),
      dns_mode = s.dns_mode or dns_mode,
      dns_server = s.dns_server or dns_addr,
      dns_tls_server_name = s.dns_tls_server_name or dns_tls_name,
      dns_path = s.dns_path or dns_path
    }
  end
end)
table.sort(aps, function(a,b) return a.slot < b.slot end)

if #aps == 0 then
  io.stderr:write("FastACL: no discovered AP networks\n")
  os.exit(2)
end

local outbounds = { { type = "direct", tag = "direct" } }
local route_rules = {}
local dns_servers = {}
local dns_rules = {}

for _, a in ipairs(aps) do
  local tag = "ap" .. a.slot
  outbounds[#outbounds + 1] = {
    type = "socks",
    tag = tag,
    server = "127.0.0.1",
    server_port = a.sport,
    version = "5"
  }
  local dns_server
  if a.dns_mode == "tcp" then
    dns_server = {
      type = "tcp",
      tag = "dns-" .. tag,
      server = a.dns_server,
      server_port = 53,
      detour = tag
    }
  else
    dns_server = {
      type = "https",
      tag = "dns-" .. tag,
      server = a.dns_server,
      server_port = 443,
      path = a.dns_path,
      tls = {
        enabled = true,
        server_name = a.dns_tls_server_name
      },
      detour = tag
    }
  end
  dns_servers[#dns_servers + 1] = dns_server
  dns_rules[#dns_rules + 1] = {
    source_ip_cidr = { a.subnet },
    action = "route",
    server = "dns-" .. tag
  }
  route_rules[#route_rules + 1] = {
    source_ip_cidr = { a.subnet },
    port = { 53 },
    action = "hijack-dns"
  }
  route_rules[#route_rules + 1] = {
    source_ip_cidr = { a.subnet },
    action = "route",
    outbound = tag
  }
end

local conf = {
  log = { level = "warn", timestamp = true },
  dns = {
    servers = dns_servers,
    rules = dns_rules,
    final = dns_servers[1] and dns_servers[1].tag or nil
  },
  inbounds = {
    {
      type = "tproxy",
      tag = "jfa-tproxy",
      listen = "0.0.0.0",
      listen_port = port
    }
  },
  outbounds = outbounds,
  route = {
    rules = route_rules,
    final = "direct"
  }
}

io.write(jsonc.stringify(conf, true))

__JFA_END_ROUTER__

__JFA_BEGIN_RELAY__
local jsonc = require "luci.jsonc"
local uci = require("luci.model.uci").cursor()
local node = arg[1] or ""
local port = tonumber(arg[2] or "0")
local outfile = arg[3] or ""
local preproxy_port = tonumber(arg[4] or "0")
if node == "" or port == 0 or outfile == "" then os.exit(2) end
local n = uci:get_all("passwall2", node)
if not n then os.exit(3) end
local t = string.lower(n.protocol or n.type or "")
local out
if t == "socks" then
  out = {
    type = "socks", tag = "proxy", server = n.address, server_port = tonumber(n.port), version = "5",
    username = n.username, password = n.password
  }
elseif t == "http" then
  out = {
    type = "http", tag = "proxy", server = n.address, server_port = tonumber(n.port),
    username = n.username, password = n.password
  }
else
  os.exit(4)
end
local outbounds = {}
if preproxy_port and preproxy_port > 0 then
  outbounds[#outbounds + 1] = {
    type = "socks",
    tag = "preproxy",
    server = "127.0.0.1",
    server_port = preproxy_port,
    version = "5"
  }
  out.detour = "preproxy"
end
outbounds[#outbounds + 1] = out

local conf = {
  log = { level = "error" },
  inbounds = { { type = "socks", tag = "in", listen = "127.0.0.1", listen_port = port } },
  outbounds = outbounds,
  route = { final = "proxy" }
}
local f = assert(io.open(outfile, "w"))
f:write(jsonc.stringify(conf, true))
f:close()

__JFA_END_RELAY__

__JFA_BEGIN_DISCOVER__
local jsonc = require "luci.jsonc"
local sys = require "luci.sys"
local uci = require("luci.model.uci").cursor()

local function split_words(v)
  local out = {}
  if type(v) == "table" then
    for _, x in ipairs(v) do
      if x and x ~= "" then out[#out + 1] = x end
    end
  elseif type(v) == "string" then
    for x in v:gmatch("%S+") do out[#out + 1] = x end
  end
  return out
end

local function ip_to_num(ip)
  local a,b,c,d = tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  a,b,c,d = tonumber(a),tonumber(b),tonumber(c),tonumber(d)
  if not a or a>255 or b>255 or c>255 or d>255 then return nil end
  return ((a*256+b)*256+c)*256+d
end

local function num_to_ip(n)
  local a = math.floor(n / 16777216) % 256
  local b = math.floor(n / 65536) % 256
  local c = math.floor(n / 256) % 256
  local d = n % 256
  return string.format("%d.%d.%d.%d", a,b,c,d)
end

local function mask_to_prefix(mask)
  if not mask or mask == "" then return 24 end
  local p = tonumber(mask)
  if p and p >= 0 and p <= 32 then return p end
  local n = ip_to_num(mask)
  if not n then return nil end
  local bits = 0
  local seen_zero = false
  for i = 31, 0, -1 do
    local bit = math.floor(n / (2^i)) % 2
    if bit == 1 then
      if seen_zero then return nil end
      bits = bits + 1
    else
      seen_zero = true
    end
  end
  return bits
end

local function cidr_from(ip, mask)
  if not ip or ip == "" then return nil end
  local bare, slash = tostring(ip):match("^([^/]+)/(%d+)$")
  if bare then
    ip = bare
    mask = slash
  end
  local n = ip_to_num(ip)
  local p = mask_to_prefix(mask)
  if not n or not p then return nil end
  local block = 2^(32-p)
  local net = math.floor(n / block) * block
  return num_to_ip(net) .. "/" .. tostring(p)
end

local function network_ipv4(net)
  local ip = uci:get("network", net, "ipaddr")
  local mask = uci:get("network", net, "netmask")
  if type(ip) == "table" then ip = ip[1] end
  local cidr = cidr_from(ip, mask)
  if cidr then return cidr, tostring(ip):match("^([^/]+)") end

  local raw = sys.exec("ubus call network.interface." .. string.format("%q", net) .. " status 2>/dev/null")
  if raw and raw ~= "" then
    local ok, st = pcall(jsonc.parse, raw)
    if ok and type(st) == "table" and type(st["ipv4-address"]) == "table" then
      local a = st["ipv4-address"][1]
      if a and a.address and a.mask then
        return cidr_from(a.address, a.mask), a.address
      end
    end
  end
  return nil
end

local lan_cidr = nil
do
  local ip = uci:get("network", "lan", "ipaddr")
  local mask = uci:get("network", "lan", "netmask")
  if type(ip) == "table" then ip = ip[1] end
  lan_cidr = cidr_from(ip, mask)
end

local ignore = {
  lan=true, wan=true, wan6=true, loopback=true, wwan=true
}

local by_net = {}
uci:foreach("wireless", "wifi-iface", function(s)
  if tostring(s.disabled or "0") ~= "1" and tostring(s.mode or "ap") == "ap" then
    local ssid = s.ssid or s[".name"] or "WiFi"
    for _, net in ipairs(split_words(s.network)) do
      if not ignore[net] then
        local cidr, router_ip = network_ipv4(net)
        if cidr and cidr ~= lan_cidr then
          local item = by_net[net]
          if not item then
            item = {
              network = net,
              subnet = cidr,
              router_ip = router_ip or "",
              ssids = {}
            }
            by_net[net] = item
          end
          local found=false
          for _,v in ipairs(item.ssids) do if v == ssid then found=true break end end
          if not found then item.ssids[#item.ssids+1]=ssid end
        end
      end
    end
  end
end)

local items = {}
for _, item in pairs(by_net) do
  item.ssid = table.concat(item.ssids, " / ")
  item._sort = ip_to_num((item.subnet or ""):match("^([^/]+)$") or (item.subnet or ""):match("^([^/]+)/")) or 0
  items[#items+1] = item
end

table.sort(items, function(a,b)
  if a._sort == b._sort then return a.network < b.network end
  return a._sort < b._sort
end)

local old = {}
uci:foreach("juliang_fastacl", "ap", function(s)
  local data = {
    node = s.node,
    dns_mode = s.dns_mode,
    dns_server = s.dns_server,
    dns_tls_server_name = s.dns_tls_server_name,
    dns_path = s.dns_path
  }
  if s.network and s.network ~= "" then old["net:" .. s.network] = data end
  if s.subnet and s.subnet ~= "" then old["subnet:" .. s.subnet] = data end
end)

-- Discovery must be transactional. During early boot WiFi/netifd may not be
-- ready yet. Never erase a working persistent FastACL topology on a 0-result scan.
if #items == 0 then
  io.write(jsonc.stringify({ ok = false, count = 0, aps = {}, preserved = true, error = "NO_AP_READY" }, true))
  os.exit(2)
end

-- Remove only AP slot sections after we already have a valid replacement set.
local dels = {}
uci:foreach("juliang_fastacl", "ap", function(s) dels[#dels+1]=s[".name"] end)
for _,name in ipairs(dels) do uci:delete("juliang_fastacl", name) end

for i,item in ipairs(items) do
  local sec = "ap" .. i
  uci:section("juliang_fastacl", "ap", sec, {
    slot = tostring(i),
    network = item.network,
    ssid = item.ssid,
    subnet = item.subnet,
    router_ip = item.router_ip or "",
    socks_port = tostring(13100+i),
    preproxy_port = tostring(14100+i)
  })
  local prev = old["net:"..item.network] or old["subnet:"..item.subnet]
  if prev then
    if prev.node and prev.node ~= "" then uci:set("juliang_fastacl", sec, "node", prev.node) end
    if prev.dns_mode and prev.dns_mode ~= "" then uci:set("juliang_fastacl", sec, "dns_mode", prev.dns_mode) end
    if prev.dns_server and prev.dns_server ~= "" then uci:set("juliang_fastacl", sec, "dns_server", prev.dns_server) end
    if prev.dns_tls_server_name and prev.dns_tls_server_name ~= "" then uci:set("juliang_fastacl", sec, "dns_tls_server_name", prev.dns_tls_server_name) end
    if prev.dns_path and prev.dns_path ~= "" then uci:set("juliang_fastacl", sec, "dns_path", prev.dns_path) end
  end
end
uci:set("juliang_fastacl", "main", "ap_count", tostring(#items))
uci:commit("juliang_fastacl")

io.write(jsonc.stringify({ ok = (#items > 0), count = #items, aps = items }, true))

__JFA_END_DISCOVER__

__JFA_BEGIN_CTRL__
module("luci.controller.juliang_fastacl", package.seeall)

function index()
    local page = entry({"admin", "services", "juliang_fastacl"}, call("handle"), nil)
    page.leaf = true
    page.dependent = false
end

local function write_json(t)
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    http.prepare_content("application/json")
    http.write(jsonc.stringify(t))
end

local function ap_sections(uci)
    local out = {}
    uci:foreach("juliang_fastacl", "ap", function(s)
        local n = tonumber(s.slot or (s[".name"] or ""):match("^ap(%d+)$"))
        if n then
            out[#out + 1] = {
                n = n,
                ap = "AP" .. n,
                section = s[".name"] or ("ap" .. n),
                ssid = s.ssid or ("AP" .. n),
                network = s.network or "",
                subnet = s.subnet or "",
                router_ip = s.router_ip or "",
                socks_port = tonumber(s.socks_port or "") or (13100 + n),
                preproxy_port = tonumber(s.preproxy_port or "") or (14100 + n),
                node = s.node or ""
            }
        end
    end)
    table.sort(out, function(a,b) return a.n < b.n end)
    return out
end

local function ap_number(uci, v)
    local n = tonumber((v or ""):match("^AP(%d+)$"))
    if not n or n < 1 then return nil end
    if uci:get("juliang_fastacl", "ap" .. n) ~= "ap" then return nil end
    return n
end

local function read_ip(n)
    local f = io.open("/tmp/juliang-fastacl/ap" .. n .. ".ip", "r")
    if not f then return "" end
    local ip = (f:read("*l") or ""):gsub("%s+", "")
    f:close()
    return ip
end

local function runtime_status()
    local f = io.open("/tmp/juliang-fastacl/router.pid", "r")
    if not f then return "stopped" end
    local pid = tonumber(f:read("*l") or "")
    f:close()
    if not pid then return "stopped" end
    local sys = require "luci.sys"
    if sys.call("kill -0 " .. pid .. " >/dev/null 2>&1") ~= 0 then return "stopped" end
    local port = tonumber(require("luci.model.uci").cursor():get("juliang_fastacl", "main", "tproxy_port") or "12345")
    local cmd = "(ss -lnt 2>/dev/null; ss -lnu 2>/dev/null; netstat -lnt 2>/dev/null; netstat -lnu 2>/dev/null) | grep -q ':" .. port .. " '"
    local listener = sys.call(cmd) == 0
    local nft = sys.call("nft list table inet juliang_fastacl >/dev/null 2>&1") == 0
    local rule = sys.call("ip rule show 2>/dev/null | grep -q 'fwmark 0x66/0xff.*lookup 100'") == 0
    return (listener and nft and rule) and "running" or "broken"
end

local function exec_json(cmd)
    local sys = require "luci.sys"
    local jsonc = require "luci.jsonc"
    local raw = sys.exec(cmd .. " 2>/tmp/juliang-fastacl/luci-error.log")
    local ok, data = pcall(jsonc.parse, raw or "")
    if ok and type(data) == "table" then return data end
    return { ok = false, error = "ENGINE_ERROR", detail = raw or "" }
end

local function is_special_protocol(p)
    return p == "_shunt" or p == "_balancing" or p == "_urltest" or p == "_iface"
end

local function preproxy_options(uci, current)
    local out = {}
    uci:foreach("passwall2", "nodes", function(s)
        local id = s[".name"] or ""
        local proto = s.protocol or ""
        local chained = s.chain_proxy or ""
        if id ~= "" and id ~= current and not is_special_protocol(proto) and chained == "" then
            out[#out + 1] = {
                id = id,
                remarks = s.remarks or id,
                type = s.type or "",
                protocol = proto
            }
        end
    end)
    table.sort(out, function(a,b) return (a.remarks or "") < (b.remarks or "") end)
    return out
end

function handle()
    local http = require "luci.http"
    local util = require "luci.util"
    local uci = require("luci.model.uci").cursor()
    local action = http.formvalue("action") or "status"
    local aps = ap_sections(uci)

    if action == "status" then
        local map, ap_to_node, ips, labels = {}, {}, {}, {}
        local ap_meta = {}

        for _, a in ipairs(aps) do
            local node = uci:get("juliang_fastacl", a.section, "node") or ""
            ap_to_node[a.ap] = node
            ips[a.ap] = read_ip(a.n)
            labels[a.ap] = a.ssid
            ap_meta[#ap_meta + 1] = {
                ap = a.ap,
                slot = a.n,
                ssid = a.ssid,
                network = a.network,
                subnet = a.subnet,
                router_ip = a.router_ip,
                socks_port = a.socks_port
            }
            if node ~= "" then
                map[node] = map[node] or {}
                map[node][#map[node] + 1] = a.ap
            end
        end

        local preproxy = {}
        uci:foreach("passwall2", "nodes", function(s)
            local id = s[".name"] or ""
            if id ~= "" then
                local pp = s.preproxy_node or ""
                preproxy[id] = {
                    enabled = (s.chain_proxy == "1" and pp ~= ""),
                    id = pp,
                    remarks = pp ~= "" and (uci:get("passwall2", pp, "remarks") or pp) or ""
                }
            end
        end)

        write_json({
            ok = true,
            engine = runtime_status(),
            count = #aps,
            aps = ap_meta,
            map = map,
            ap_to_node = ap_to_node,
            wireless_labels = labels,
            ips = ips,
            preproxy = preproxy
        })
        return
    end

    local node = http.formvalue("node") or ""
    local node_cfg = node ~= "" and uci:get_all("passwall2", node) or nil

    if action == "assign" then
        local ap = http.formvalue("ap") or ""
        local n = ap_number(uci, ap)
        if not n then write_json({ok=false,error="BAD_AP"}); return end
        if not node_cfg or node_cfg[".type"] ~= "nodes" then write_json({ok=false,error="BAD_NODE"}); return end
        local exclusive = http.formvalue("exclusive") ~= "0"
        local verb = exclusive and "move" or "switch"
        write_json(exec_json("/usr/bin/juliang-fastacl " .. verb .. " " .. ap .. " " .. util.shellquote(node)))
        return
    end

    if action == "preproxy_options" then
        if not node_cfg or node_cfg[".type"] ~= "nodes" then write_json({ok=false,error="BAD_NODE"}); return end
        write_json({
            ok = true,
            current = node_cfg.preproxy_node or "",
            enabled = node_cfg.chain_proxy == "1",
            options = preproxy_options(uci, node)
        })
        return
    end

    if action == "set_preproxy" then
        if not node_cfg or node_cfg[".type"] ~= "nodes" then write_json({ok=false,error="BAD_NODE"}); return end
        local pre = http.formvalue("preproxy") or ""
        if pre == node then write_json({ok=false,error="PREPROXY_SELF"}); return end

        if pre ~= "" then
            local p = uci:get_all("passwall2", pre)
            if not p or p[".type"] ~= "nodes" or is_special_protocol(p.protocol or "") then
                write_json({ok=false,error="BAD_PREPROXY"}); return
            end
            if (p.chain_proxy or "") ~= "" then
                write_json({ok=false,error="PREPROXY_ALREADY_CHAINED"}); return
            end
        end

        local old_chain = node_cfg.chain_proxy or ""
        local old_pre = node_cfg.preproxy_node or ""
        if pre == "" then
            uci:delete("passwall2", node, "chain_proxy")
            uci:delete("passwall2", node, "preproxy_node")
        else
            uci:set("passwall2", node, "chain_proxy", "1")
            uci:set("passwall2", node, "preproxy_node", pre)
        end
        uci:commit("passwall2")

        local affected, failed = {}, nil
        for _, a in ipairs(aps) do
            if (uci:get("juliang_fastacl", a.section, "node") or "") == node then
                local rr = exec_json("/usr/bin/juliang-fastacl switch " .. a.ap .. " " .. util.shellquote(node))
                if not rr.ok then failed = rr; break end
                affected[#affected + 1] = a.ap
            end
        end

        if failed then
            if old_chain == "" then uci:delete("passwall2", node, "chain_proxy")
            else uci:set("passwall2", node, "chain_proxy", old_chain) end
            if old_pre == "" then uci:delete("passwall2", node, "preproxy_node")
            else uci:set("passwall2", node, "preproxy_node", old_pre) end
            uci:commit("passwall2")
            for _, ap in ipairs(affected) do
                exec_json("/usr/bin/juliang-fastacl switch " .. ap .. " " .. util.shellquote(node))
            end
            write_json({ok=false,error="PREPROXY_START_FAILED",detail=failed,rolled_back=true})
            return
        end

        local ip = ""
        if #affected > 0 then
            local sys = require "luci.sys"
            ip = (sys.exec("/usr/bin/juliang-fastacl probe " .. affected[1] .. " 2>/dev/null") or ""):gsub("%s+", "")
        end
        write_json({
            ok = true,
            action = "set_preproxy",
            node = node,
            preproxy = pre,
            preproxy_remarks = pre ~= "" and (uci:get("passwall2", pre, "remarks") or pre) or "",
            affected = affected,
            ip = ip
        })
        return
    end

    if action == "clear_node" then
        if not node_cfg or node_cfg[".type"] ~= "nodes" then write_json({ok=false,error="BAD_NODE"}); return end
        local cleared = {}
        for _, a in ipairs(aps) do
            if (uci:get("juliang_fastacl", a.section, "node") or "") == node then
                local rr = exec_json("/usr/bin/juliang-fastacl clear " .. a.ap)
                if rr.ok then cleared[#cleared + 1] = a.ap end
            end
        end
        write_json({ok=true,action="clear_node",node=node,cleared=cleared})
        return
    end

    if action == "probe" then
        local ap = http.formvalue("ap") or ""
        local n = ap_number(uci, ap)
        if not n then write_json({ok=false,error="BAD_AP"}); return end
        local sys = require "luci.sys"
        local ip = (sys.exec("/usr/bin/juliang-fastacl probe " .. ap .. " 2>/dev/null") or ""):gsub("%s+", "")
        write_json({ok = ip ~= "" and ip ~= "-", ap=ap, ip=ip})
        return
    end

    if action == "rediscover" then
        local rr = exec_json("/usr/bin/juliang-fastacl discover")
        write_json(rr)
        return
    end

    write_json({ok=false,error="BAD_ACTION"})
end

__JFA_END_CTRL__

__JFA_BEGIN_INIT__
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=95
STOP=10

start_service() {
    [ "$(uci -q get juliang_fastacl.main.enabled 2>/dev/null)" = "1" ] || return 0

    # PassWall2 is retained only as the node database/UI. Its late S99 start
    # would otherwise see FastACL's /tmp/etc/passwall2/bin children and stop
    # them. Keep its service disabled permanently while FastACL owns dataplane.
    /etc/init.d/passwall2 disable >/dev/null 2>&1 || true

    mkdir -p /tmp/juliang-fastacl

    procd_open_instance
    procd_set_param command /usr/bin/juliang-fastacl-guard
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    /usr/bin/juliang-fastacl stop >/dev/null 2>&1 || true
}

service_triggers() {
    procd_add_reload_trigger juliang_fastacl
}

__JFA_END_INIT__

__JFA_BEGIN_HOTPLUG__
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$(uci -q get juliang_fastacl.main.enabled 2>/dev/null)" = "1" ] || exit 0
[ "$INTERFACE" = "loopback" ] && exit 0

# Dynamic version: any interface may be one of the discovered wireless
# networks (a1/a2/tk1/custom names). Re-assert only FastACL's nft/policy rules.
# Node relays and the FastACL router are not restarted.
(
    sleep 1
    /usr/bin/juliang-fastacl firewall >/dev/null 2>&1 || true
) &

__JFA_END_HOTPLUG__

__JFA_BEGIN_PW2_ACL_JSON__
#!/usr/bin/lua
local sys=require "luci.sys"
local jsonc=require "luci.jsonc"
local uci=require("luci.model.uci").cursor()
local fs=require "nixio.fs"

local force=arg[1]=="--refresh"
local CACHE="/tmp/pw2-acl-ip-cache.json"
local JOBDIR="/tmp/pw2-acl-ip-jobs"

local function rf(p)
  local f=io.open(p,"r")
  if not f then return nil end
  local d=f:read("*a")
  f:close()
  return d
end

local function wf(p,d)
  local f=io.open(p,"w")
  if f then f:write(d); f:close() end
end

local function q(s)
  return "'"..tostring(s or ""):gsub("'","'\\''").."'"
end

local function parse(t)
  local r={status="FAILED",ip="",country="",country_code="",city="",isp="",asn="",port=""}
  for line in (t or ""):gmatch("[^\r\n]+") do
    local k,v=line:match("^([A-Z_]+)=(.*)$")
    if k=="STATUS" then r.status=v
    elseif k=="PORT" then r.port=v
    elseif k=="IP" then r.ip=v
    elseif k=="COUNTRY" then r.country=v
    elseif k=="COUNTRY_CODE" then r.country_code=v
    elseif k=="CITY" then r.city=v
    elseif k=="ISP" then r.isp=v
    elseif k=="ASN" then r.asn=v end
  end
  return r
end

local function valid(id)
  return id and id~="" and id~="default" and id~="tcp" and id~="udp" and uci:get("passwall2",id)=="nodes"
end

local var=rf("/tmp/etc/passwall2/var") or ""
local global=var:match('ACL_GLOBAL_node="([^"]+)"') or uci:get("passwall2","@global[0]","node") or ""
local rows={}
local base="/tmp/etc/passwall2/acl"

if fs.stat(base) then
  for sid in fs.dir(base) do
    if sid~="." and sid~=".." and sid~="default" and sid~="acl_default" then
      local src=rf(base.."/"..sid.."/source_list")
      local idx=src and tonumber(src:match("172%.16%.(%d+)%.0/24"))
      if idx and idx>=1 then
        local node=var:match('ACL_'..sid..'_node="([^"]+)"') or ""
        if not valid(node) then node=uci:get("passwall2",sid,"node") or "" end
        if (node=="" or node=="default") and (uci:get("passwall2",sid,"mode") or "")=="2" then node=global end
        if not valid(node) then node="" end
        rows[#rows+1]={index=idx,name="A"..idx,section=sid,network="172.16."..idx..".0/24",node=node}
      end
    end
  end
end

table.sort(rows,function(a,b)return a.index<b.index end)

local sig={}
for _,r in ipairs(rows) do sig[#sig+1]=r.name..":"..(r.node or "") end
local signature=table.concat(sig,";")

local oldraw=rf(CACHE)
local old,oldres=nil,{}
if oldraw then
  local ok,d=pcall(jsonc.parse,oldraw)
  if ok and type(d)=="table" then old=d end
end

if old and type(old.rows)=="table" then
  for _,r in ipairs(old.rows) do
    if r.node and r.status=="OK" and r.ip and r.ip~="" then
      oldres[r.node]={status=r.status,ip=r.ip,country=r.country or "",country_code=r.country_code or "",city=r.city or "",isp=r.isp or "",asn=r.asn or "",port=r.port or ""}
    end
  end
end

if not force and old and old.signature==signature and tonumber(old.generated or 0)>0 and os.time()-tonumber(old.generated)<180 then
  io.write(oldraw)
  os.exit(0)
end

local unique={}
for _,r in ipairs(rows) do if valid(r.node) then unique[r.node]=true end end

local results,jobs={},{}
sys.call("rm -rf "..q(JOBDIR))
sys.call("mkdir -p "..q(JOBDIR))

local n=0
for node,_ in pairs(unique) do
  if not force and oldres[node] then
    results[node]=oldres[node]
  else
    n=n+1
    jobs[#jobs+1]={node=node,port=11880+n,out=JOBDIR.."/"..node..".out"}
  end
end

if #jobs>0 then
  local cmds={}
  for _,j in ipairs(jobs) do
    cmds[#cmds+1]=string.format("/usr/bin/pw2-node-ip-probe %s %d > %s 2>&1 &",q(j.node),j.port,q(j.out))
  end
  cmds[#cmds+1]="wait"
  sys.call("sh -c "..q(table.concat(cmds,"\n")))
  for _,j in ipairs(jobs) do results[j.node]=parse(rf(j.out) or "") end
end

for node,r in pairs(results) do r.remarks=uci:get("passwall2",node,"remarks") or node end

for _,r in ipairs(rows) do
  if not valid(r.node) then
    r.status="NO_NODE"; r.remarks="--"; r.ip=""; r.country=""; r.country_code=""; r.city=""; r.isp=""; r.asn=""; r.port=""
  else
    local x=results[r.node] or {}
    r.status=x.status or "FAILED"
    r.remarks=x.remarks or r.node
    r.ip=x.ip or ""
    r.country=x.country or ""
    r.country_code=x.country_code or ""
    r.city=x.city or ""
    r.isp=x.isp or ""
    r.asn=x.asn or ""
    r.port=x.port or ""
  end
end

local out={status="OK",count=#rows,generated=os.time(),signature=signature,detected_nodes=#jobs,rows=rows}
local enc=jsonc.stringify(out)
wf(CACHE,enc)
sys.call("rm -rf "..q(JOBDIR))
io.write(enc)

__JFA_END_PW2_ACL_JSON__

__JFA_BEGIN_PW_ACL_JSON__
#!/usr/bin/lua
local sys=require "luci.sys"
local jsonc=require "luci.jsonc"
local uci=require("luci.model.uci").cursor()
local fs=require "nixio.fs"

local force=arg[1]=="--refresh"
local CACHE="/tmp/pw-acl-ip-cache.json"
local JOBDIR="/tmp/pw-acl-ip-jobs"

local function rf(p)
  local f=io.open(p,"r")
  if not f then return nil end
  local d=f:read("*a")
  f:close()
  return d
end

local function wf(p,d)
  local f=io.open(p,"w")
  if f then f:write(d); f:close() end
end

local function q(s)
  return "'"..tostring(s or ""):gsub("'","'\\''").."'"
end

local function parse(t)
  local r={status="FAILED",ip="",country="",country_code="",city="",isp="",asn="",port=""}
  for line in (t or ""):gmatch("[^\r\n]+") do
    local k,v=line:match("^([A-Z_]+)=(.*)$")
    if k=="STATUS" then r.status=v
    elseif k=="PORT" then r.port=v
    elseif k=="IP" then r.ip=v
    elseif k=="COUNTRY" then r.country=v
    elseif k=="COUNTRY_CODE" then r.country_code=v
    elseif k=="CITY" then r.city=v
    elseif k=="ISP" then r.isp=v
    elseif k=="ASN" then r.asn=v end
  end
  return r
end

local function valid(id)
  if not id or id=="" or id=="tcp" or id=="udp" or id=="default" or id=="direct" then return false end
  local t=uci:get("passwall",id)
  return t=="nodes" or t=="socks"
end

local var=rf("/tmp/etc/passwall/var") or ""
local acl_enabled=uci:get("passwall","@global[0]","acl_enable") or "0"
local rows={}
local base="/tmp/etc/passwall/acl"

if fs.stat(base) then
  for sid in fs.dir(base) do
    if sid~="." and sid~=".." and sid~="default" and sid~="acl_default" then
      local src=rf(base.."/"..sid.."/source_list")
      local idx=src and tonumber(src:match("172%.16%.(%d+)%.0/24"))
      if idx and idx>=1 then
        local tcp=var:match('ACL_'..sid..'_tcp_node="([^"]+)"') or ""
        local udp=var:match('ACL_'..sid..'_udp_node="([^"]+)"') or ""
        local old=var:match('ACL_'..sid..'_node="([^"]+)"') or ""
        if not valid(tcp) then tcp=old end
        if not valid(udp) then udp=old end
        if not valid(tcp) then tcp=uci:get("passwall",sid,"node") or "" end
        if not valid(udp) then udp=tcp end
        if not valid(tcp) then tcp="" end
        if not valid(udp) then udp="" end
        rows[#rows+1]={index=idx,name="A"..idx,section=sid,network="172.16."..idx..".0/24",tcp_node=tcp,udp_node=udp,node=tcp~="" and tcp or udp}
      end
    end
  end
end

table.sort(rows,function(a,b)return a.index<b.index end)

local sig={}
for _,r in ipairs(rows) do sig[#sig+1]=r.name..":TCP="..(r.tcp_node or "")..":UDP="..(r.udp_node or "") end
local signature=table.concat(sig,";")

local oldraw=rf(CACHE)
local old,oldres=nil,{}
if oldraw then
  local ok,d=pcall(jsonc.parse,oldraw)
  if ok and type(d)=="table" then old=d end
end
if old and type(old.node_results)=="table" then oldres=old.node_results end

if not force and old and old.signature==signature and tonumber(old.generated or 0)>0 and os.time()-tonumber(old.generated)<180 then
  io.write(oldraw)
  os.exit(0)
end

local unique={}
for _,r in ipairs(rows) do
  if valid(r.tcp_node) then unique[r.tcp_node]=true end
  if valid(r.udp_node) then unique[r.udp_node]=true end
end

local results,jobs={},{}
sys.call("rm -rf "..q(JOBDIR))
sys.call("mkdir -p "..q(JOBDIR))

for node,_ in pairs(unique) do
  if not force and oldres[node] and oldres[node].status=="OK" then
    results[node]=oldres[node]
  else
    local port=tonumber(var:match('node_'..node..'_socks_port="(%d+)"') or "")
    if port then
      jobs[#jobs+1]={node=node,port=port,out=JOBDIR.."/"..node..".out"}
    else
      results[node]={status="SOCKS_PORT_NOT_FOUND",port="",ip="",country="",country_code="",city="",isp="",asn=""}
    end
  end
end

if #jobs>0 then
  local cmds={}
  for _,j in ipairs(jobs) do cmds[#cmds+1]=string.format("/usr/bin/proxy-socks-ip-probe %d > %s 2>&1 &",j.port,q(j.out)) end
  cmds[#cmds+1]="wait"
  sys.call("sh -c "..q(table.concat(cmds,"\n")))
  for _,j in ipairs(jobs) do results[j.node]=parse(rf(j.out) or "") end
end

for node,r in pairs(results) do r.remarks=uci:get("passwall",node,"remarks") or node end

for _,r in ipairs(rows) do
  local en=uci:get("passwall",r.section,"enabled") or "0"
  if acl_enabled~="1" then
    r.status="ACL_DISABLED"
  elseif en~="1" then
    r.status="DISABLED"
  elseif r.tcp_node=="" and r.udp_node=="" then
    r.status="NO_NODE"
  else
    local t=results[r.tcp_node] or {}
    local u=results[r.udp_node] or {}
    r.tcp_status=t.status or "NO_NODE"
    r.udp_status=u.status or "NO_NODE"
    r.tcp_port=t.port or ""
    r.udp_port=u.port or ""
    r.tcp_ip=t.ip or ""
    r.udp_ip=u.ip or ""
    r.tcp_remarks=t.remarks or r.tcp_node or ""
    r.udp_remarks=u.remarks or r.udp_node or ""

    if r.tcp_node~="" and r.tcp_node==r.udp_node then
      r.status=t.status or "FAILED"
      r.port=t.port or ""
      r.ip=t.ip or ""
      r.country=t.country or ""
      r.country_code=t.country_code or ""
      r.city=t.city or ""
      r.isp=t.isp or ""
      r.asn=t.asn or ""
      r.remarks=t.remarks or r.tcp_node
    else
      r.status=(r.tcp_status=="OK" and r.udp_status=="OK") and "OK" or "PARTIAL"
      r.port="TCP:"..(r.tcp_port~="" and r.tcp_port or "--").." UDP:"..(r.udp_port~="" and r.udp_port or "--")
      r.ip="TCP: "..(r.tcp_ip~="" and r.tcp_ip or "--").." / UDP: "..(r.udp_ip~="" and r.udp_ip or "--")
      r.remarks="TCP: "..(r.tcp_remarks~="" and r.tcp_remarks or "--").." / UDP: "..(r.udp_remarks~="" and r.udp_remarks or "--")
      r.country=t.country or ""
      r.country_code=t.country_code or ""
      r.city=t.city or ""
      r.isp=t.isp or ""
      r.asn=t.asn or ""
    end
  end
  r.ip=r.ip or ""
  r.remarks=r.remarks or "--"
  r.port=r.port or ""
  r.country=r.country or ""
  r.country_code=r.country_code or ""
  r.city=r.city or ""
  r.isp=r.isp or ""
  r.asn=r.asn or ""
end

local out={status="OK",count=#rows,generated=os.time(),signature=signature,detected_nodes=#jobs,acl_enabled=acl_enabled,node_results=results,rows=rows}
local enc=jsonc.stringify(out)
wf(CACHE,enc)
sys.call("rm -rf "..q(JOBDIR))
io.write(enc)

__JFA_END_PW_ACL_JSON__

__JFA_BEGIN_PW2_ACL_VIEW__
<%
local _jfa_uci=require("luci.model.uci").cursor()
local _jfa_enabled=(_jfa_uci:get("juliang_fastacl","main","enabled")=="1")
if not _jfa_enabled then
%>
<div class="cbi-section">
<h3>ACL 实际出口 IP</h3>
<p>
<input id="passwall2_acl_refresh" type="button" class="cbi-button cbi-button-action" value="重新检测全部 ACL" onclick="passwall2AclLoad(true);" />
<span id="passwall2_acl_msg" style="margin-left:12px"></span>
</p>
<div style="overflow-x:auto">
<table class="table cbi-section-table">
<thead><tr><th>ACL</th><th>网段</th><th>当前节点</th><th>SOCKS</th><th>出口 IP</th><th>国家/地区</th><th>ISP</th><th>状态</th></tr></thead>
<tbody id="passwall2_acl_rows"><tr><td colspan="8">读取中...</td></tr></tbody>
</table>
</div>
</div>
<script type="text/javascript">
//<![CDATA[
function passwall2Esc(v){return String(v||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
function passwall2AclLoad(force){
  var b=document.getElementById('passwall2_acl_refresh'),m=document.getElementById('passwall2_acl_msg');
  if(b)b.disabled=true;
  if(m)m.textContent=force?'正在并行检测...':'正在读取...';
  XHR.get('<%=luci.dispatcher.build_url("admin","services","passwall2","acl_exit_ip_status")%>',{refresh:force?'1':'0'},function(x,d){
    if(b)b.disabled=false;
    var o=d;try{if(typeof o==='string')o=JSON.parse(o);if((!o||typeof o!=='object')&&x&&x.responseText)o=JSON.parse(x.responseText);}catch(e){o=null;}
    var body=document.getElementById('passwall2_acl_rows');
    if(!o||o.status!=='OK'){body.innerHTML='<tr><td colspan="8">检测失败</td></tr>';return;}
    var h='',ok=0;
    (o.rows||[]).forEach(function(r){
      var good=r.status==='OK';if(good)ok++;
      var cc=r.country||'--';if(r.country_code)cc+=' ('+r.country_code+')';
      h+='<tr><td><strong>'+passwall2Esc(r.name)+'</strong></td><td>'+passwall2Esc(r.network)+'</td><td>'+passwall2Esc(r.remarks||r.node||'--')+'</td><td>'+passwall2Esc(r.port?'127.0.0.1:'+r.port:'--')+'</td><td><strong style="color:'+(good?'#159957':'#e43f3b')+'">'+passwall2Esc(r.ip||'--')+'</strong></td><td>'+passwall2Esc(cc)+'</td><td>'+passwall2Esc(r.isp||'--')+'</td><td>'+(good?'<span style="color:#159957">● 正常</span>':'<span style="color:#e43f3b">'+passwall2Esc(r.status||'失败')+'</span>')+'</td></tr>';
    });
    body.innerHTML=h||'<tr><td colspan="8">没有找到可检测的 ACL</td></tr>';
    if(m)m.innerHTML='<span style="color:#159957">'+ok+'/'+(o.count||0)+' 正常，本次实际检测节点：'+(o.detected_nodes||0)+'</span>';
  });
}
passwall2AclLoad(false);
//]]>
</script>

<% end %>

__JFA_END_PW2_ACL_VIEW__

__JFA_BEGIN_PW_ACL_VIEW__
<%
local _jfa_uci=require("luci.model.uci").cursor()
local _jfa_enabled=(_jfa_uci:get("juliang_fastacl","main","enabled")=="1")
if not _jfa_enabled then
%>
<div class="cbi-section">
<h3>ACL 实际出口 IP</h3>
<p>
<input id="passwall_acl_refresh" type="button" class="cbi-button cbi-button-action" value="重新检测全部 ACL" onclick="passwallAclLoad(true);" />
<span id="passwall_acl_msg" style="margin-left:12px"></span>
</p>
<div style="overflow-x:auto">
<table class="table cbi-section-table">
<thead><tr><th>ACL</th><th>网段</th><th>当前节点</th><th>SOCKS</th><th>出口 IP</th><th>国家/地区</th><th>ISP</th><th>状态</th></tr></thead>
<tbody id="passwall_acl_rows"><tr><td colspan="8">读取中...</td></tr></tbody>
</table>
</div>
</div>
<script type="text/javascript">
//<![CDATA[
function passwallEsc(v){return String(v||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
function passwallAclLoad(force){
  var b=document.getElementById('passwall_acl_refresh'),m=document.getElementById('passwall_acl_msg');
  if(b)b.disabled=true;
  if(m)m.textContent=force?'正在并行检测...':'正在读取...';
  XHR.get('<%=luci.dispatcher.build_url("admin","services","passwall","acl_exit_ip_status")%>',{refresh:force?'1':'0'},function(x,d){
    if(b)b.disabled=false;
    var o=d;try{if(typeof o==='string')o=JSON.parse(o);if((!o||typeof o!=='object')&&x&&x.responseText)o=JSON.parse(x.responseText);}catch(e){o=null;}
    var body=document.getElementById('passwall_acl_rows');
    if(!o||o.status!=='OK'){body.innerHTML='<tr><td colspan="8">检测失败</td></tr>';return;}
    var h='',ok=0;
    (o.rows||[]).forEach(function(r){
      var good=r.status==='OK';if(good)ok++;
      var cc=r.country||'--';if(r.country_code)cc+=' ('+r.country_code+')';
      h+='<tr><td><strong>'+passwallEsc(r.name)+'</strong></td><td>'+passwallEsc(r.network)+'</td><td>'+passwallEsc(r.remarks||r.node||'--')+'</td><td>'+passwallEsc(r.port?'127.0.0.1:'+r.port:'--')+'</td><td><strong style="color:'+(good?'#159957':'#e43f3b')+'">'+passwallEsc(r.ip||'--')+'</strong></td><td>'+passwallEsc(cc)+'</td><td>'+passwallEsc(r.isp||'--')+'</td><td>'+(good?'<span style="color:#159957">● 正常</span>':'<span style="color:#e43f3b">'+passwallEsc(r.status||'失败')+'</span>')+'</td></tr>';
    });
    body.innerHTML=h||'<tr><td colspan="8">没有找到可检测的 ACL</td></tr>';
    if(m)m.innerHTML='<span style="color:#159957">'+ok+'/'+(o.count||0)+' 正常，本次实际检测节点：'+(o.detected_nodes||0)+'</span>';
  });
}
passwallAclLoad(false);
//]]>
</script>

<% end %>

__JFA_END_PW_ACL_VIEW__

__JFA_BEGIN_PW2_ACL_REFRESH__
<div style="padding:8px 0 14px 0">
<input id="passwall2_acl_quick" type="button" class="cbi-button cbi-button-action" value="快速更新实际出口 IP" onclick="passwall2AclRefresh(false);" />
<input id="passwall2_acl_full" type="button" class="cbi-button cbi-button-apply" value="强制重新检测全部" onclick="passwall2AclRefresh(true);" />
<span id="passwall2_acl_state" style="margin-left:12px">读取检测状态...</span>
</div>
<script type="text/javascript">
//<![CDATA[
function passwall2AclRefresh(force){
  var a=document.getElementById('passwall2_acl_quick'),b=document.getElementById('passwall2_acl_full'),s=document.getElementById('passwall2_acl_state');
  a.disabled=b.disabled=true;s.textContent=force?'正在并行重新检测全部节点...':'正在快速更新...';
  XHR.get('<%=luci.dispatcher.build_url("admin","services","passwall2","acl_exit_ip_status")%>',{refresh:force?'1':'0'},function(x,d){
    a.disabled=b.disabled=false;
    var o=d;try{if(typeof o==='string')o=JSON.parse(o);if((!o||typeof o!=='object')&&x&&x.responseText)o=JSON.parse(x.responseText);}catch(e){o=null;}
    if(!o||o.status!=='OK'){s.innerHTML='<span style="color:#e43f3b">检测失败</span>';return;}
    var ok=0;(o.rows||[]).forEach(function(r){if(r.status==='OK')ok++;});
    s.innerHTML='<span style="color:#159957">'+ok+'/'+(o.count||0)+' 正常，实际检测节点：'+(o.detected_nodes||0)+'</span>';
    setTimeout(function(){location.reload();},600);
  });
}
//]]>
</script>

<% end %>

__JFA_END_PW2_ACL_REFRESH__

__JFA_BEGIN_PW_ACL_REFRESH__
<div style="padding:8px 0 14px 0">
<input id="passwall_acl_quick" type="button" class="cbi-button cbi-button-action" value="快速更新实际出口 IP" onclick="passwallAclRefresh(false);" />
<input id="passwall_acl_full" type="button" class="cbi-button cbi-button-apply" value="强制重新检测全部" onclick="passwallAclRefresh(true);" />
<span id="passwall_acl_state" style="margin-left:12px">读取检测状态...</span>
</div>
<script type="text/javascript">
//<![CDATA[
function passwallAclRefresh(force){
  var a=document.getElementById('passwall_acl_quick'),b=document.getElementById('passwall_acl_full'),s=document.getElementById('passwall_acl_state');
  a.disabled=b.disabled=true;s.textContent=force?'正在并行重新检测全部节点...':'正在快速更新...';
  XHR.get('<%=luci.dispatcher.build_url("admin","services","passwall","acl_exit_ip_status")%>',{refresh:force?'1':'0'},function(x,d){
    a.disabled=b.disabled=false;
    var o=d;try{if(typeof o==='string')o=JSON.parse(o);if((!o||typeof o!=='object')&&x&&x.responseText)o=JSON.parse(x.responseText);}catch(e){o=null;}
    if(!o||o.status!=='OK'){s.innerHTML='<span style="color:#e43f3b">检测失败</span>';return;}
    var ok=0;(o.rows||[]).forEach(function(r){if(r.status==='OK')ok++;});
    s.innerHTML='<span style="color:#159957">'+ok+'/'+(o.count||0)+' 正常，实际检测节点：'+(o.detected_nodes||0)+'</span>';
    setTimeout(function(){location.reload();},600);
  });
}
//]]>
</script>

<% end %>

__JFA_END_PW_ACL_REFRESH__
