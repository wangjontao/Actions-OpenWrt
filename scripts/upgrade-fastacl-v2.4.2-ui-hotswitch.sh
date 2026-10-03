#!/bin/sh
set -eu

REPO="wangjontao/Actions-OpenWrt"
PIN="5e0be15b9d0d8d58009ed2a8547bdc9db6066490"
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
  if command -v usleep >/dev/null 2>&1; then
    usleep 200000
  else
    sleep 1
  fi
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
    # The listener/dataplane is already healthy; refresh the exit IP in background.
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

  s=s:gsub('ensure_dataplane && switch_ok=1','if ensure_dataplane || { fast_pause; ensure_dataplane; }; then switch_ok=1; fi',1)
  write(core,s)
end

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
sed -i 's/juliang-fastacl-v242-routing\.js?v=2422/juliang-fastacl-v242-routing.js?v=2423/g' "$CONSOLE"
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
grep -q 'probe_async' "$CORE"
grep -q '出口IP后台检测中' "$CONSOLE"
grep -q 'juliang-fastacl-v242-routing.js?v=2423' "$CONSOLE"
grep -q '节点分配（链式代理）' "$ROUTE_JS"

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo '[OK] FastACL 2.4.2 compact UI + hot-switch optimization installed'
echo '[OK] wireless mode panel is collapsible; node table labelled 节点分配（链式代理）'
echo '[OK] exit-IP probe moved to background; successful switching no longer waits up to 6s for ipify'
echo '[OK] local listener uses fast polling with an 8s slow-start grace window to reduce false rollback'
echo "[INFO] Backup: $BK"
echo '[INFO] No FastACL dataplane restart was performed; browser cache key bumped to 2423'
