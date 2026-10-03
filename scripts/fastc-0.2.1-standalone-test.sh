#!/bin/sh
set -eu

REPO="wangjontao/Actions-OpenWrt"
PIN="ca96f0a2cd816062aaf25e83721f1229b3bb0391"
BASE="https://api.github.com/repos/$REPO/contents/profiles/fastc-v010/root"
TMP="/tmp/fastc021-standalone-$$"
BAK="/etc/fastc/021-backup-$(date +%Y%m%d-%H%M%S)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT INT TERM

fetch(){
  rel="$1"; out="$2"
  mkdir -p "$(dirname "$out")"
  curl -4 --http1.1 -fL --connect-timeout 15 --max-time 180 --retry 5 --retry-delay 2 \
    -H 'Accept: application/vnd.github.raw+json' -H 'User-Agent: FastC-021-Standalone' \
    -o "$out" "$BASE/$rel?ref=$PIN"
}
lua_check(){ FC_LUA_CHECK="$1" lua -e 'local p=os.getenv("FC_LUA_CHECK"); assert(loadfile(p))'; }

echo "=================================================="
echo " FastC 0.2.1 Standalone Test"
echo " per-AP TProxy + mihomo hot reload + no FastACL fallback"
echo "=================================================="
mkdir -p "$TMP" "$BAK" /etc/fastc

OLD_PID="$(pidof mihomo 2>/dev/null || true)"
echo "[INFO] mihomo PID before update: ${OLD_PID:-none}"

FILES="usr/libexec/fastc-generate.lua usr/bin/fastc-dataplane usr/bin/fastc-mode usr/bin/fastc-guard"
for f in $FILES; do
  [ -f "/$f" ] && { mkdir -p "$BAK/$(dirname "$f")"; cp -af "/$f" "$BAK/$f"; } || true
  echo "[GET] $f"
  fetch "$f" "$TMP/$f"
  [ -s "$TMP/$f" ] || { echo "[ERROR] empty file: $f" >&2; exit 1; }
done

lua_check "$TMP/usr/libexec/fastc-generate.lua"
grep -q 'FastACL-aligned per-AP TProxy architecture' "$TMP/usr/libexec/fastc-generate.lua" || { echo "[ERROR] 0.2.1 generator marker missing" >&2; exit 1; }
grep -q 'tproxy-map.tsv' "$TMP/usr/bin/fastc-dataplane" || { echo "[ERROR] per-AP dataplane marker missing" >&2; exit 1; }
grep -q 'no FastACL fallback' "$TMP/usr/bin/fastc-mode" || { echo "[ERROR] standalone mode marker missing" >&2; exit 1; }
grep -q 'standalone mode remains fail-closed' "$TMP/usr/bin/fastc-guard" || { echo "[ERROR] standalone guard marker missing" >&2; exit 1; }

for f in $FILES; do
  mkdir -p "/$(dirname "$f")"
  cp -af "$TMP/$f" "/$f"
done
chmod 0755 /usr/libexec/fastc-generate.lua /usr/bin/fastc-dataplane /usr/bin/fastc-mode /usr/bin/fastc-guard

# Preserve nodes/bindings/chains; only update runtime policy knobs.
uci set fastc.main.version='0.2.1-dev'
uci set fastc.main.mode='fastc'
uci set fastc.main.enabled='1'
uci set fastc.main.standalone_test='1'
uci set fastc.main.fallback_fastacl='0'
uci set fastc.main.dataplane='tproxy'
uci set fastc.main.tun_enabled='0'
uci set fastc.main.tproxy_port='7895'
uci set fastc.main.ap_tproxy_base='19000'
uci set fastc.main.mark='0x67'
uci set fastc.main.route_table='101'
uci commit fastc

# Replace the legacy guardian process without touching mihomo. procd will respawn guardian.
pkill -f '/usr/bin/fastc-guard' >/dev/null 2>&1 || true
sleep 1

# FastC-only test mode owns the dataplane. The mode command stops FastACL,
# hot-loads mihomo when already alive, and never starts FastACL on failure.
rm -f /tmp/fastc-transaction.lock /tmp/fastc-guard.fail 2>/dev/null || true
/usr/bin/fastc-mode fastc

NEW_PID="$(pidof mihomo 2>/dev/null || true)"
echo "[INFO] mihomo PID after update: ${NEW_PID:-none}"
if [ -n "$OLD_PID" ] && [ -n "$NEW_PID" ] && [ "$OLD_PID" != "$NEW_PID" ]; then
  echo "[ERROR] live mihomo PID changed: $OLD_PID -> $NEW_PID" >&2
  exit 1
fi

/usr/bin/fastc-dataplane check

echo "[OK] FastC 0.2.1 standalone test installed"
echo "[OK] FastACL is stopped/disabled and is not used as fallback"
echo "[OK] each discovered AP subnet is pinned to its own mihomo TProxy listener"
echo "[OK] DNS remains fail-closed through FastC DNS hijack"
echo "[OK] live mihomo config updates use API hot reload"
echo "[INFO] backup: $BAK"
echo "[INFO] tproxy map: /etc/fastc/tproxy-map.tsv"
