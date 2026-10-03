#!/bin/sh
set -eu

REPO="wangjontao/Actions-OpenWrt"
PIN="18df5c52cfbda4a5d6a62c5a1be5230e943d8ecb"
BASE="https://api.github.com/repos/$REPO/contents/profiles/fastc-v010/root"
TMP="/tmp/fastc020-fix1-$$"
BAK="/etc/fastc/fix1-backup-$(date +%Y%m%d-%H%M%S)"
OLD_MODE="$(uci -q get fastc.main.mode 2>/dev/null || echo fastc)"
OLD_ENABLED="$(uci -q get fastc.main.enabled 2>/dev/null || echo 1)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT INT TERM

fetch(){
  rel="$1"; out="$2"
  mkdir -p "$(dirname "$out")"
  curl -4 --http1.1 -fL --connect-timeout 15 --max-time 180 --retry 5 --retry-delay 2 \
    -H 'Accept: application/vnd.github.raw+json' -H 'User-Agent: FastC-020-Fix1' \
    -o "$out" "$BASE/$rel?ref=$PIN"
}
lua_check(){ FC_LUA_CHECK="$1" lua -e 'local p=os.getenv("FC_LUA_CHECK"); assert(loadfile(p))'; }

echo "=================================================="
echo " FastC 0.2.0 Fix1 In-Place Recovery"
echo " no FastACL dependency + no live mihomo restart"
echo "=================================================="
mkdir -p "$TMP" "$BAK" /etc/fastc

OLD_PID="$(pidof mihomo 2>/dev/null || true)"
echo "[INFO] mihomo PID before fix: ${OLD_PID:-none}"
echo "[INFO] original traffic mode: $OLD_MODE"

# Quiesce the legacy Guardian without stopping mihomo or touching the active
# TProxy / fail-closed dataplane. The old guard ignores non-fastc modes.
touch /tmp/fastc-transaction.lock
uci set fastc.main.mode='repair'
uci commit fastc
sleep 1

FILES="usr/libexec/fastc-generate.lua usr/libexec/fastc-hotctl.lua usr/libexec/fastc-sync.lua usr/bin/fastc-guard"
for f in $FILES; do
  [ -f "/$f" ] && { mkdir -p "$BAK/$(dirname "$f")"; cp -af "/$f" "$BAK/$f"; } || true
  echo "[GET] $f"
  fetch "$f" "$TMP/$f"
  [ -s "$TMP/$f" ] || { echo "[ERROR] empty file: $f" >&2; exit 1; }
done

lua_check "$TMP/usr/libexec/fastc-generate.lua"
lua_check "$TMP/usr/libexec/fastc-hotctl.lua"
lua_check "$TMP/usr/libexec/fastc-sync.lua"
grep -q 'Stable hot-control baseline' "$TMP/usr/libexec/fastc-generate.lua" || { echo "[ERROR] generator marker missing" >&2; exit 1; }
grep -q 'BIND_DB="/etc/fastc/bindings.json"' "$TMP/usr/libexec/fastc-sync.lua" || { echo "[ERROR] bindings sync marker missing" >&2; exit 1; }
grep -q 'never restart a live mihomo instance' "$TMP/usr/bin/fastc-guard" || { echo "[ERROR] guardian no-restart marker missing" >&2; exit 1; }

for f in $FILES; do mkdir -p "/$(dirname "$f")"; cp -af "$TMP/$f" "/$f"; done
chmod 0755 /usr/libexec/fastc-generate.lua /usr/libexec/fastc-hotctl.lua /usr/libexec/fastc-sync.lua /usr/bin/fastc-guard

lua /usr/libexec/fastc-generate.lua >/tmp/fastc020-fix1-generate.json 2>/tmp/fastc020-fix1-generate.err || {
  echo "[ERROR] config generation failed" >&2
  cat /tmp/fastc020-fix1-generate.err >&2 || true
  uci set fastc.main.mode="$OLD_MODE"; uci set fastc.main.enabled="$OLD_ENABLED"; uci commit fastc
  rm -f /tmp/fastc-transaction.lock
  exit 1
}
/usr/bin/mihomo -t -d /etc/fastc -f /etc/fastc/config.yaml >/tmp/fastc020-fix1-check.log 2>&1 || {
  echo "[ERROR] mihomo config validation failed" >&2
  cat /tmp/fastc020-fix1-check.log >&2 || true
  uci set fastc.main.mode="$OLD_MODE"; uci set fastc.main.enabled="$OLD_ENABLED"; uci commit fastc
  rm -f /tmp/fastc-transaction.lock
  exit 1
}

if pidof mihomo >/dev/null 2>&1 && curl -fsS --connect-timeout 1 --max-time 1 http://127.0.0.1:9097/version >/dev/null 2>&1; then
  echo "[INFO] applying corrected config with in-process hot reload"
  lua /usr/libexec/fastc-reload.lua >/tmp/fastc020-fix1-reload.json 2>/tmp/fastc020-fix1-reload.err || {
    echo "[ERROR] hot reload failed" >&2
    cat /tmp/fastc020-fix1-reload.err >&2 || true
    uci set fastc.main.mode="$OLD_MODE"; uci set fastc.main.enabled="$OLD_ENABLED"; uci commit fastc
    rm -f /tmp/fastc-transaction.lock
    exit 1
  }
else
  echo "[ERROR] live mihomo/API is unavailable; refusing to restart it automatically" >&2
  uci set fastc.main.mode="$OLD_MODE"; uci set fastc.main.enabled="$OLD_ENABLED"; uci commit fastc
  rm -f /tmp/fastc-transaction.lock
  exit 1
fi

# Re-assert new source-of-truth state after the hot reload.
lua /usr/libexec/fastc-sync.lua >/tmp/fastc020-fix1-sync.json 2>/tmp/fastc020-fix1-sync.err || {
  echo "[ERROR] selector/chain sync failed" >&2
  cat /tmp/fastc020-fix1-sync.err >&2 || true
  cat /tmp/fastc020-fix1-sync.json >&2 || true
  uci set fastc.main.mode="$OLD_MODE"; uci set fastc.main.enabled="$OLD_ENABLED"; uci commit fastc
  rm -f /tmp/fastc-transaction.lock
  exit 1
}

NEW_PID="$(pidof mihomo 2>/dev/null || true)"
echo "[INFO] mihomo PID after fix: ${NEW_PID:-none}"
if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$NEW_PID" ]; then
  echo "[ERROR] mihomo PID changed unexpectedly: $OLD_PID -> $NEW_PID" >&2
  uci set fastc.main.mode="$OLD_MODE"; uci set fastc.main.enabled="$OLD_ENABLED"; uci commit fastc
  rm -f /tmp/fastc-transaction.lock
  exit 1
fi

echo "[OK] mihomo PID unchanged"

uci set fastc.main.version='0.2.0-dev-fix1'
uci set fastc.main.mode="$OLD_MODE"
uci set fastc.main.enabled="$OLD_ENABLED"
uci commit fastc
rm -f /tmp/fastc-guard.fail /tmp/fastc-transaction.lock 2>/dev/null || true

echo "[OK] FastC 0.2.0 Fix1 installed in-place"
echo "[OK] direct nodes do not receive unnecessary dialer-proxy"
echo "[OK] chained nodes use explicit dialer-proxy only"
echo "[OK] selector sync reads bindings.json/chains.json"
echo "[OK] guardian will not restart a live mihomo"
echo "[OK] no FastACL handoff was required"
echo "[INFO] traffic mode restored to: $OLD_MODE"
echo "[INFO] backup: $BAK"
