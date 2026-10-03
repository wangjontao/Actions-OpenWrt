#!/bin/sh
set -eu

REPO="wangjontao/Actions-OpenWrt"
PIN="7c0e7a3532c5b4f486459555bfd9e2aa51886cb3"
API="https://api.github.com/repos/$REPO/contents"
TMP="/tmp/jfa242-hotswitch-$$"
BK="/etc/juliang-fastacl/v2.4.2-hotswitch-backup-$(date +%Y%m%d-%H%M%S)"
CORE="/usr/bin/juliang-fastacl"
CONSOLE="/usr/lib/lua/luci/view/juliang_fastacl/console.htm"
ROUTE_JS="/www/luci-static/resources/juliang-fastacl-v242-routing.js"
mkdir -p "$TMP" "$BK"
trap 'rm -rf "$TMP"' EXIT INT TERM

get(){
  path="$1"; out="$2"
  curl -4 --http1.1 -fsSL --connect-timeout 15 --max-time 90 --retry 5 --retry-delay 1 \
    -H 'Accept: application/vnd.github.raw+json' \
    -H 'User-Agent: FastACL-242-HotSwitch' \
    -o "$out" "$API/$path?ref=$PIN"
  [ -s "$out" ] || { echo "[ERROR] empty payload: $path" >&2; exit 1; }
}

[ -s "$CORE" ] || { echo "[ERROR] $CORE missing" >&2; exit 1; }
[ -s "$CONSOLE" ] || { echo "[ERROR] $CONSOLE missing" >&2; exit 1; }

get "profiles/fastacl-v9/root/www/luci-static/resources/juliang-fastacl-v242-routing.js" "$TMP/routing.js"
grep -q '节点分配（链式代理）' "$TMP/routing.js"
grep -q 'jfa242_route_summary' "$TMP/routing.js"
grep -q "document.createElement('details')" "$TMP/routing.js"

cp -af "$CORE" "$BK/juliang-fastacl"
cp -af "$CONSOLE" "$BK/console.htm"
[ -e "$ROUTE_JS" ] && cp -af "$ROUTE_JS" "$BK/juliang-fastacl-v242-routing.js" || true

JFA_CORE="$CORE" JFA_CONSOLE="$CONSOLE" lua <<'LUA'
local core=assert(os.getenv('JFA_CORE'))
local console=assert(os.getenv('JFA_CONSOLE'))

local function read(path)
  local f=assert(io.open(path,'rb')); local s=f:read('*a'); f:close(); return s
end
local function write(path,s)
  local f=assert(io.open(path,'wb')); f:write(s); f:close()
end
local function replace_plain(s,old,new,label)
  local p=s:find(old,1,true)
  assert(p, 'patch anchor not found: '..label)
  return s:sub(1,p-1)..new..s:sub(p+#old)
end

local s=read(core)
if not s:find('FastACL 2.4.2 hot%-switch async probe') then
  local anchor='\nap_count(){'
  local helper=[[

# FastACL 2.4.2 hot-switch async probe
fast_pause(){
  # BusyBox sleep on current OpenWrt accepts fractions. Keep fallbacks for
  # older builds so normal switches poll at ~200ms instead of whole seconds.
  sleep 0.2 2>/dev/null && return 0
  command -v usleep >/dev/null 2>&1 && { usleep 200000; return 0; }
  sleep 1
}

wait_tcp_listener(){
  local port="$1" timeout="${2:-8}" deadline
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    has_tcp_listener "$port" && return 0
    fast_pause
  done
  return 1
}

wait_any_listener_pid(){
  local port="$1" pid="$2" timeout="${3:-8}" deadline
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    kill -0 "$pid" >/dev/null 2>&1 || return 1
    has_any_listener "$port" && return 0
    fast_pause
  done
  return 1
}
]]
  local p=s:find(anchor,1,true); assert(p,'ap_count anchor missing')
  s=s:sub(1,p-1)..helper..s:sub(p)

  s=replace_plain(s,[=[  i=0
  while [ "$i" -lt 6 ]; do
    has_tcp_listener "$port" && return 0
    sleep 1
    i=$((i+1))
  done
]=],[=[  # Poll quickly when supported, but allow a slower node up to 8 seconds
  # before rollback. Normal healthy switches return as soon as the listener is up.
  wait_tcp_listener "$port" 8 && return 0
]=],'preproxy listener wait')

  s=replace_plain(s,[=[  i=0
  while [ "$i" -lt 5 ]; do
    has_tcp_listener "$port" && return 0
    sleep 1; i=$((i+1))
  done
]=],[=[  # Fast local readiness check: healthy nodes usually return in well under 1s;
  # slow cores still get an 8s grace window instead of a premature rollback.
  wait_tcp_listener "$port" 8 && return 0
]=],'AP listener wait')

  s=replace_plain(s,[=[  i=0
  while [ "$i" -lt 5 ]; do
    kill -0 "$pid" >/dev/null 2>&1 || { cat "$RUN_DIR/router.log"; return 1; }
    if has_any_listener "$tport"; then
      return 0
    fi
    sleep 1
    i=$((i+1))
  done
]=],[=[  if wait_any_listener_pid "$tport" "$pid" 8; then
    return 0
  fi
]=],'router listener wait')

  s=replace_plain(s,[=[    ip="$(probe_ap "$n")"
    printf '%s\n' "$ip" > "$RUN_DIR/ap$n.ip"
    t1="$(date +%s)"; sec=$((t1-t0))
    remark="$(uci -q get $APP.$node.remarks 2>/dev/null || echo "$node")"
    save_state
    printf '{"ok":true,"ap":"AP%s","node":"%s","remark":"%s","ip":"%s","seconds":%s,"dataplane":"running"}\n' "$n" "$node" "$(echo "$remark" | sed 's/"/\\"/g')" "$ip" "$sec"
]=],[=[    # Do not hold up a successful hot switch on an Internet IP service.
    # Listener/dataplane is already healthy; refresh exit IP in background.
    rm -f "$RUN_DIR/ap$n.ip"
    (
      ip="$(probe_ap "$n")"
      tmpip="$RUN_DIR/ap$n.ip.tmp.$$"
      printf '%s\n' "$ip" > "$tmpip"
      mv -f "$tmpip" "$RUN_DIR/ap$n.ip"
    ) >/dev/null 2>&1 &
    t1="$(date +%s)"; sec=$((t1-t0))
    remark="$(uci -q get $APP.$node.remarks 2>/dev/null || echo "$node")"
    save_state
    printf '{"ok":true,"ap":"AP%s","node":"%s","remark":"%s","ip":"-","seconds":%s,"dataplane":"running","probe_async":true}\n' "$n" "$node" "$(echo "$remark" | sed 's/"/\\"/g')" "$sec"
]=],'async exit probe')

  -- One transient dataplane observation should not trigger rollback. Retry once
  -- after the short local poll before treating the target as unhealthy.
  s=s:gsub('ensure_dataplane && switch_ok=1','if ensure_dataplane || { fast_pause; ensure_dataplane; }; then switch_ok=1; fi',1)
end

if not s:find('FastACL 2.4.2 make%-before%-break') then
  s=replace_plain(s,[=[  # Unique-binding means MOVE, not duplicate-then-delete. Stop old AP relay(s)
  # first to avoid protocol/plugin/shared-resource collisions, but keep UCI
  # mappings until the target is confirmed healthy so rollback is possible.
  for i in $sources; do
    kill_ap "$i"
  done

  if result="$(switch_node "$ap" "$node")"; then
    for i in $sources; do
      uci -q delete $CFG.ap$i.node
]=],[=[  # FastACL 2.4.2 make-before-break
  # Keep source relay(s) alive until the target listener/dataplane is confirmed.
  # AP slots use different local SOCKS ports/flags, so this avoids an outage
  # during a move and leaves the previous path intact if the target fails.
  if result="$(switch_node "$ap" "$node")"; then
    for i in $sources; do
      kill_ap "$i"
      uci -q delete $CFG.ap$i.node
]=],'make-before-break move')

  s=replace_plain(s,[=[  # Target failed: source UCI mappings were intentionally left intact; restart
  # them so the previous working wireless AP is restored.
  for i in $sources; do
    start_ap "$i" >/dev/null 2>&1 || true
  done
  printf '{"ok":false,"ap":"%s","node":"%s","error":"NODE_START_FAILED","rolled_back_sources":true,"diagnostic":"%s"}\n' "$ap" "$node" "$RUN_DIR/ap$n-start-error.log"
]=],[=[  # Target failed before source teardown; previous source relay(s) stay live.
  printf '{"ok":false,"ap":"%s","node":"%s","error":"NODE_START_FAILED","rolled_back_sources":true,"source_kept_live":true,"diagnostic":"%s"}\n' "$ap" "$node" "$RUN_DIR/ap$n-start-error.log"
]=],'failed move keeps source live')
end
write(core,s)

local c=read(console)
if not c:find('出口IP后台检测中',1,true) then
  c=replace_plain(c,"modalMsg('正在切换并验证真实出口…');","modalMsg('正在热切换节点…');",'assign progress text')
  c=replace_plain(c,[=[      if(r&&r.ok){modalMsg('✓ 已切换；出口 '+(r.ip||'-')+(r.seconds!=null?'；'+r.seconds+'s':''),true);loadStatus()}
]=],[=[      if(r&&r.ok){
        if(r.probe_async){modalMsg('✓ 已切换'+(r.seconds!=null?'；'+r.seconds+'s':'')+'；出口IP后台检测中',true);loadStatus();setTimeout(loadStatus,1800);setTimeout(loadStatus,5000)}
        else {modalMsg('✓ 已切换；出口 '+(r.ip||'-')+(r.seconds!=null?'；'+r.seconds+'s':''),true);loadStatus()}
      }
]=],'assign async result')
  write(console,c)
end
LUA

cp -af "$TMP/routing.js" "$ROUTE_JS"
# Normalize any previous routing cache key and load the compact UI once.
JFA_CONSOLE="$CONSOLE" lua <<'LUA'
local path=assert(os.getenv('JFA_CONSOLE'))
local f=assert(io.open(path,'rb')); local s=f:read('*a'); f:close()
s=s:gsub('<script type="text/javascript" src="/luci%-static/resources/juliang%-fastacl%-v242%-routing%.js%?v=%d+"></script>%s*','')
local foot='<%+footer%>'
local p=assert(s:find(foot,1,true),'console footer missing')
local tag='<script type="text/javascript" src="/luci-static/resources/juliang-fastacl-v242-routing.js?v=2424"></script>\n'
s=s:sub(1,p-1)..tag..s:sub(p)
local o=assert(io.open(path,'wb')); o:write(s); o:close()
LUA
chmod 0755 "$CORE"
chmod 0644 "$CONSOLE" "$ROUTE_JS"

sh -n "$CORE" || {
  echo '[ERROR] patched core syntax failed; restoring backup' >&2
  cp -af "$BK/juliang-fastacl" "$CORE"
  cp -af "$BK/console.htm" "$CONSOLE"
  [ -s "$BK/juliang-fastacl-v242-routing.js" ] && cp -af "$BK/juliang-fastacl-v242-routing.js" "$ROUTE_JS" || true
  exit 1
}
grep -q 'FastACL 2.4.2 hot-switch async probe' "$CORE"
grep -q 'FastACL 2.4.2 make-before-break' "$CORE"
grep -q 'probe_async' "$CORE"
grep -q '出口IP后台检测中' "$CONSOLE"
grep -q 'juliang-fastacl-v242-routing.js?v=2424' "$CONSOLE"
grep -q '节点分配（链式代理）' "$ROUTE_JS"
grep -q "document.createElement('details')" "$ROUTE_JS"

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo '[OK] FastACL 2.4.2 compact UI + HotSwitch v2 installed'
echo '[OK] 无线出口模式: collapsed by default and remembers open/closed state'
echo '[OK] empty area title: 节点分配（链式代理）'
echo '[OK] exit-IP probe is asynchronous; successful switch no longer waits up to 6s for ipify'
echo '[OK] listener readiness uses ~200ms polling with an 8s slow-start grace window'
echo '[OK] exclusive move uses make-before-break; old source stays live until target is healthy'
echo '[INFO] FastACL dataplane was not restarted'
echo "[INFO] Backup: $BK"
echo '[INFO] Ctrl+F5 refresh FastACL console'
