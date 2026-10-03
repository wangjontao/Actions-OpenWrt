#!/bin/sh
set -eu

REPO="wangjontao/Actions-OpenWrt"
PIN="b14c29fa25f53a3ee339ecf16feba878e1edc923"
API="https://api.github.com/repos/$REPO/contents/profiles/fastc-v010/root"
TMP="/tmp/fastc020-$$"
BACKUP="/etc/fastc/v020-backup-$(date +%Y%m%d-%H%M%S)"
OLD_MODE="$(uci -q get fastc.main.mode 2>/dev/null || echo fastacl)"
OLD_ENABLED="$(uci -q get fastc.main.enabled 2>/dev/null || echo 0)"
OLD_CORE_PATH="$(uci -q get fastc.main.core_path 2>/dev/null || echo /usr/bin/mihomo)"
OLD_CORE_VERSION="$(uci -q get fastc.main.core_version 2>/dev/null || true)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT INT TERM

fetch(){
  rel="$1"; out="$2"
  mkdir -p "$(dirname "$out")"
  echo "[GET] $rel"
  curl -4 --http1.1 -fL --connect-timeout 15 --max-time 180 --retry 5 --retry-delay 2 \
    -H 'Accept: application/vnd.github.raw+json' -H 'User-Agent: FastC-020-Installer' \
    -o "$out" "$API/$rel?ref=$PIN"
}
need(){ grep -q "$1" "$2" || { echo "[ERROR] validation failed: $3" >&2; exit 1; }; echo "[OK] $3"; }
lua_check(){ FC_LUA_CHECK="$1" lua -e 'local p=os.getenv("FC_LUA_CHECK"); assert(p and p~=""); assert(loadfile(p))'; }

echo "=================================================="
echo " FastC 0.2.0-dev Rebuild Installer"
echo " persistent mihomo + atomic bindings + hot control"
echo "=================================================="
mkdir -p "$TMP" "$BACKUP" /etc/fastc

FILES="etc/config/fastc usr/libexec/fastc-state.lua usr/libexec/fastc-hotctl.lua usr/libexec/fastc-reload.lua usr/libexec/fastc-generate.lua usr/libexec/fastc-discover.lua usr/libexec/fastc-import.lua usr/libexec/fastc-sync.lua usr/lib/lua/luci/controller/fastc.lua usr/lib/lua/luci/controller/fastc_v020.lua usr/lib/lua/luci/controller/fastc_runtime.lua usr/lib/lua/luci/controller/fastc_topology.lua usr/lib/lua/luci/view/fastc/console_v020.htm"
for f in $FILES; do
  [ -f "/$f" ] && { mkdir -p "$BACKUP/$(dirname "$f")"; cp -af "/$f" "$BACKUP/$f"; } || true
  fetch "$f" "$TMP/$f"
  [ -s "$TMP/$f" ] || { echo "[ERROR] empty: $f" >&2; exit 1; }
done

need "option version '0.2.0-dev'" "$TMP/etc/config/fastc" "0.2.0 config model"
need "last-good-bindings.json" "$TMP/usr/libexec/fastc-state.lua" "atomic binding rollback"
need "CHAIN_LOOP" "$TMP/usr/libexec/fastc-state.lua" "chain loop protection"
need "SELECTOR_APPLY_FAILED" "$TMP/usr/libexec/fastc-hotctl.lua" "selector-only wireless switching"
need "configs?force=true" "$TMP/usr/libexec/fastc-reload.lua" "no-restart config hot reload"
need "FastC 0.2.0-dev" "$TMP/usr/libexec/fastc-generate.lua" "0.2.0 generator"
need "Migration is first-run only" "$TMP/usr/libexec/fastc-generate.lua" "last-good snapshot preservation"
need "one shared diagnostic listener" "$TMP/usr/libexec/fastc-generate.lua" "single shared probe listener"
need "FastC 0.2.0 重构控制台" "$TMP/usr/lib/lua/luci/view/fastc/console_v020.htm" "node-first UI"
for f in "$TMP/usr/libexec/fastc-state.lua" "$TMP/usr/libexec/fastc-hotctl.lua" "$TMP/usr/libexec/fastc-reload.lua" "$TMP/usr/libexec/fastc-generate.lua" "$TMP/usr/lib/lua/luci/controller/fastc_v020.lua"; do lua_check "$f"; done

echo "[INFO] installing files; node database is preserved"
for f in $FILES; do mkdir -p "/$(dirname "$f")"; cp -af "$TMP/$f" "/$f"; done
chmod 0755 /usr/libexec/fastc-state.lua /usr/libexec/fastc-hotctl.lua /usr/libexec/fastc-reload.lua /usr/libexec/fastc-generate.lua /usr/libexec/fastc-discover.lua /usr/libexec/fastc-import.lua /usr/libexec/fastc-sync.lua
chmod 0644 /usr/lib/lua/luci/controller/fastc.lua /usr/lib/lua/luci/controller/fastc_v020.lua /usr/lib/lua/luci/controller/fastc_runtime.lua /usr/lib/lua/luci/controller/fastc_topology.lua /usr/lib/lua/luci/view/fastc/console_v020.htm

# Route the existing FastC menu to the new 0.2.0 view. Keep the legacy API
# controller installed for mode/core compatibility, but the 0.2 UI uses v020 API.
sed -i -e 's/template("fastc\/console_v018")/template("fastc\/console_v020")/' \
       -e 's/template("fastc\/console")/template("fastc\/console_v020")/' \
       /usr/lib/lua/luci/controller/fastc.lua
# Ensure import/delete in the new view use the 0.2 no-restart API.
sed -i "s/post(API,{action:'delete'/post(VAPI,{action:'delete'/g; s/post(API,{action:'import'/post(VAPI,{action:'import'/g" /usr/lib/lua/luci/view/fastc/console_v020.htm

[ -f /etc/fastc/nodes.json ] || echo '[]' >/etc/fastc/nodes.json
[ -f /etc/fastc/bindings.json ] || echo '{}' >/etc/fastc/bindings.json
[ -f /etc/fastc/chains.json ] || echo '{}' >/etc/fastc/chains.json
uci set fastc.main.version='0.2.0-dev'
uci set fastc.main.mode="$OLD_MODE"
uci set fastc.main.enabled="$OLD_ENABLED"
uci set fastc.main.core_path="$OLD_CORE_PATH"
[ -n "$OLD_CORE_VERSION" ] && uci set fastc.main.core_version="$OLD_CORE_VERSION" || true
uci set fastc.main.hot_switch='1'
uci set fastc.main.exclusive_binding='1'
uci set fastc.main.fail_closed='1'
uci set fastc.main.dataplane='tproxy'
uci set fastc.main.tun_enabled='0'
uci set fastc.main.ui_exit_panel='collapsed'
uci commit fastc

lua /usr/libexec/fastc-discover.lua >/tmp/fastc020-discover.json 2>/tmp/fastc020-discover.err || true
lua /usr/libexec/fastc-state.lua migrate >/tmp/fastc020-migrate.json 2>/tmp/fastc020-migrate.err || { echo "[ERROR] state migration failed"; cat /tmp/fastc020-migrate.err; exit 1; }
lua /usr/libexec/fastc-generate.lua >/tmp/fastc020-generate.json 2>/tmp/fastc020-generate.err || { echo "[ERROR] config generation failed"; cat /tmp/fastc020-generate.err; exit 1; }
/usr/bin/mihomo -t -d /etc/fastc -f /etc/fastc/config.yaml >/tmp/fastc020-check.log 2>&1 || { echo "[ERROR] mihomo validation failed"; cat /tmp/fastc020-check.log; exit 1; }

OLD_PID="$(pidof mihomo 2>/dev/null || true)"
if [ -n "$OLD_PID" ] && curl -fsS --connect-timeout 1 --max-time 1 http://127.0.0.1:9097/version >/dev/null 2>&1; then
  echo "[INFO] mihomo is running; applying 0.2 config with API hot reload only"
  lua /usr/libexec/fastc-reload.lua >/tmp/fastc020-reload.json 2>/tmp/fastc020-reload.err || { echo "[ERROR] hot reload failed; running mihomo was not restarted"; cat /tmp/fastc020-reload.err; exit 1; }
  NEW_PID="$(pidof mihomo 2>/dev/null || true)"
  [ "$OLD_PID" = "$NEW_PID" ] || { echo "[ERROR] mihomo PID changed unexpectedly: $OLD_PID -> $NEW_PID" >&2; exit 1; }
  echo "[OK] mihomo PID unchanged: $NEW_PID"
else
  echo "[INFO] mihomo not running; configuration installed without starting/restarting core"
fi

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] FastC 0.2.0-dev phase-1 installed"
echo "[OK] node-first UI; wireless diagnostics collapsed by default"
echo "[OK] exclusive wireless binding with automatic old-node release"
echo "[OK] wireless reassignment uses selector API only"
echo "[OK] chain state is independent, loop-checked and last-good protected"
echo "[OK] chain/import/delete use in-process config hot reload; no mihomo restart"
echo "[OK] default dataplane remains TProxy + DNS hijack; TUN stays optional/off"
echo "[INFO] traffic mode preserved: $OLD_MODE"
echo "[INFO] backup: $BACKUP"
