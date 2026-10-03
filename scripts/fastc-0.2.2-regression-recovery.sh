#!/bin/sh
set -eu

REPO="wangjontao/Actions-OpenWrt"
PIN="f948b048f2fc56a44f74455aef9e5c2e4737ac93"
BASE="https://api.github.com/repos/$REPO/contents/profiles/fastc-v010/root"
TMP="/tmp/fastc022-recovery-$$"
BAK="/etc/fastc/022-backup-$(date +%Y%m%d-%H%M%S)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT INT TERM

fetch(){
  rel="$1"; out="$2"
  mkdir -p "$(dirname "$out")"
  curl -4 --http1.1 -fL --connect-timeout 15 --max-time 180 --retry 5 --retry-delay 2 \
    -H 'Accept: application/vnd.github.raw+json' -H 'User-Agent: FastC-022-Recovery' \
    -o "$out" "$BASE/$rel?ref=$PIN"
}
lua_check(){ FC_LUA_CHECK="$1" lua -e 'local p=os.getenv("FC_LUA_CHECK"); assert(loadfile(p))'; }

echo "=================================================="
echo " FastC 0.2.2 Regression-Recovery"
echo " restore 0.1.7 proven single-7895 wireless dataplane"
echo " keep 0.2 state/binding/chain/performance improvements"
echo "=================================================="
mkdir -p "$TMP" "$BAK" /etc/fastc

OLD_PID="$(pidof mihomo 2>/dev/null || true)"
echo "[INFO] mihomo PID before update: ${OLD_PID:-none}"

FILES="usr/libexec/fastc-generate.lua usr/libexec/fastc-reload.lua usr/libexec/fastc-sync.lua usr/bin/fastc-dataplane usr/bin/fastc-mode usr/bin/fastc-guard etc/init.d/fastc"
for f in $FILES; do
  if [ -f "/$f" ]; then mkdir -p "$BAK/$(dirname "$f")"; cp -af "/$f" "$BAK/$f"; fi
  echo "[GET] $f"
  fetch "$f" "$TMP/$f"
  [ -s "$TMP/$f" ] || { echo "[ERROR] empty file: $f" >&2; exit 1; }
done

lua_check "$TMP/usr/libexec/fastc-generate.lua"
lua_check "$TMP/usr/libexec/fastc-reload.lua"
lua_check "$TMP/usr/libexec/fastc-sync.lua"
grep -q '0.1.7-proven single-TProxy dataplane' "$TMP/usr/libexec/fastc-generate.lua" || { echo "[ERROR] 0.2.2 generator marker missing" >&2; exit 1; }
grep -q 'comment "fastc-all"' "$TMP/usr/bin/fastc-dataplane" || { echo "[ERROR] single-TProxy dataplane marker missing" >&2; exit 1; }
if grep -q '1900[0-9]\|1901[0-9]' "$TMP/usr/libexec/fastc-generate.lua"; then
  echo "[ERROR] stale per-AP 190xx listener architecture still present" >&2
  exit 1
fi

for f in $FILES; do
  mkdir -p "/$(dirname "$f")"
  cp -af "$TMP/$f" "/$f"
done
chmod 0755 /usr/libexec/fastc-generate.lua /usr/libexec/fastc-reload.lua /usr/libexec/fastc-sync.lua \
  /usr/bin/fastc-dataplane /usr/bin/fastc-mode /usr/bin/fastc-guard /etc/init.d/fastc

uci set fastc.main.version='0.2.2-dev'
uci set fastc.main.mode='fastc'
uci set fastc.main.enabled='1'
uci set fastc.main.standalone_test='1'
uci set fastc.main.fallback_fastacl='0'
uci set fastc.main.dataplane='tproxy'
uci set fastc.main.tun_enabled='0'
uci set fastc.main.tproxy_port='7895'
uci set fastc.main.node_probe_port='18200'
uci set fastc.main.mark='0x67'
uci set fastc.main.route_table='101'
uci commit fastc
rm -f /etc/fastc/tproxy-map.tsv /tmp/fastc-transaction.lock /tmp/fastc-guard.fail 2>/dev/null || true

# Replace only guardian process; never restart live mihomo.
pkill -f '/usr/bin/fastc-guard' >/dev/null 2>&1 || true
sleep 1

/usr/bin/fastc-mode fastc

NEW_PID="$(pidof mihomo 2>/dev/null || true)"
echo "[INFO] mihomo PID after update: ${NEW_PID:-none}"
if [ -n "$OLD_PID" ] && [ -n "$NEW_PID" ] && [ "$OLD_PID" != "$NEW_PID" ]; then
  echo "[ERROR] live mihomo PID changed: $OLD_PID -> $NEW_PID" >&2
  exit 1
fi

/usr/bin/fastc-dataplane check
nft list table inet fastc_tproxy 2>/dev/null | grep -q 'fastc-all' || { echo "[ERROR] single-TProxy nft rule not active" >&2; exit 1; }

echo "[OK] FastC 0.2.2 regression recovery installed"
echo "[OK] wireless dataplane restored to single mihomo TProxy port 7895"
echo "[OK] A1..An selection remains inside mihomo via SRC-IP-CIDR rules"
echo "[OK] nodes/bindings/chains preserved"
echo "[OK] shared node probe remains 127.0.0.1:18200"
echo "[OK] live mihomo was hot-reloaded without restart"
echo "[INFO] backup: $BAK"
