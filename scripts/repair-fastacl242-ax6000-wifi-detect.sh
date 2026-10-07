#!/bin/sh
set -eu

PIN="3ca573a5b8999be6d949671b64d66d781d939da3"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN"
TMP="/tmp/jfa242-ax6000-fix.$$"
BK="/etc/juliang-fastacl/ax6000-wifi-detect-fix-$(date +%Y%m%d-%H%M%S)"
DISCOVER="/usr/libexec/juliang-fastacl-discover.lua"
DETECT="/usr/bin/juliang-fastacl-wifi-detect"
CORE="/usr/bin/juliang-fastacl"

cleanup(){ rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

mkdir -p "$TMP" "$BK"

echo "=================================================="
echo " FastACL 2.4.2 AX6000 WiFi Detect / AP Recovery"
echo "=================================================="

command -v curl >/dev/null 2>&1 || { echo '[ERROR] curl not found'; exit 1; }
command -v lua >/dev/null 2>&1 || { echo '[ERROR] lua not found'; exit 1; }
command -v uci >/dev/null 2>&1 || { echo '[ERROR] uci not found'; exit 1; }

[ -s "$DISCOVER" ] && cp -af "$DISCOVER" "$BK/" || true
[ -s "$CORE" ] && cp -af "$CORE" "$BK/" || true
[ -s /etc/config/juliang_fastacl ] && cp -af /etc/config/juliang_fastacl "$BK/juliang_fastacl.before" || true
[ -s "$DETECT" ] && cp -af "$DETECT" "$BK/" || true

echo "[INFO] backup: $BK"

curl -4 --http1.1 -fL --connect-timeout 10 --max-time 60 --retry 3 \
  -o "$TMP/discover.lua" \
  "$BASE/profiles/fastacl-v9/root/usr/libexec/juliang-fastacl-discover.lua"

curl -4 --http1.1 -fL --connect-timeout 10 --max-time 60 --retry 3 \
  -o "$TMP/wifi-detect" \
  "$BASE/profiles/fastacl-v9/root/usr/bin/juliang-fastacl-wifi-detect"

[ -s "$TMP/discover.lua" ] || { echo '[ERROR] discover payload empty'; exit 1; }
[ -s "$TMP/wifi-detect" ] || { echo '[ERROR] detector payload empty'; exit 1; }

lua -e "assert(loadfile('$TMP/discover.lua'))"
sh -n "$TMP/wifi-detect"

grep -q 'PARTIAL_AP_READY' "$TMP/discover.lua"
grep -q 'runtime_ssids' "$TMP/discover.lua"
grep -q 'Detected A-series SSIDs' "$TMP/wifi-detect"

cp -af "$TMP/discover.lua" "$DISCOVER"
cp -af "$TMP/wifi-detect" "$DETECT"
chmod 0755 "$DETECT"
chmod 0644 "$DISCOVER"

# Add convenient subcommands to the installed FastACL launcher if not already present.
if [ -s "$CORE" ]; then
  if ! grep -q 'wifi-detect)' "$CORE"; then
    sed -i '/^[[:space:]]*discover) lua \/usr\/libexec\/juliang-fastacl-discover.lua ;;/i\  wifi-detect) /usr/bin/juliang-fastacl-wifi-detect ;;\n  discover-force) JFA_DISCOVER_FORCE=1 lua /usr/libexec/juliang-fastacl-discover.lua ;;' "$CORE"
  fi
  if grep -q 'Usage: juliang-fastacl {' "$CORE" && ! grep -q 'wifi-detect|discover-force' "$CORE"; then
    sed -i 's/|discover|firewall/|wifi-detect|discover|discover-force|firewall/' "$CORE"
  fi
  sh -n "$CORE"
fi

echo
echo "===== Runtime WiFi detection ====="
"$DETECT" || true

old_count="$(uci -q get juliang_fastacl.main.ap_count 2>/dev/null || echo 0)"
case "$old_count" in ''|*[!0-9]*) old_count=0 ;; esac

# If the broken 2.4.2 update already collapsed the topology to one AP, recover
# the newest pre-update config containing A1-A5 before running protected discovery.
if [ "$old_count" -le 1 ]; then
  REC=""
  for d in $(ls -1dt /etc/juliang-fastacl/v2.4.2-full-backup-* 2>/dev/null || true); do
    f="$d/root/etc/config/juliang_fastacl"
    [ -s "$f" ] || continue
    hits="$(grep -Ec "option network 'a[1-5]'" "$f" 2>/dev/null || true)"
    [ "${hits:-0}" -ge 5 ] 2>/dev/null || continue
    REC="$f"
    break
  done

  if [ -n "$REC" ]; then
    echo "[RECOVER] restoring A1-A5 topology from: $REC"
    cp -af "$REC" /etc/config/juliang_fastacl
    uci -q set juliang_fastacl.main.version='2.4.2'
    uci -q commit juliang_fastacl
  else
    echo "[WARN] no A1-A5 pre-update backup found; detector/discovery fix is installed, current config left intact"
  fi
fi

echo
echo "===== Protected discover ====="
set +e
OUT="$(lua "$DISCOVER" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"

case "$RC" in
  0)
    echo '[OK] discovery completed with full/healthy topology'
    ;;
  2|3)
    echo '[SAFE] discovery refused to overwrite existing topology because WiFi is not fully ready'
    echo '[SAFE] existing AP bindings were preserved'
    ;;
  *)
    echo "[ERROR] discover returned $RC"
    exit "$RC"
    ;;
esac

if [ -x "$CORE" ]; then
  "$CORE" repair >/tmp/jfa242-ax6000-repair.log 2>&1 || {
    echo '[WARN] FastACL repair returned non-zero; diagnostic follows:'
    cat /tmp/jfa242-ax6000-repair.log 2>/dev/null || true
  }
  "$CORE" save-state >/dev/null 2>&1 || true
fi

echo
echo "===== Final FastACL topology ====="
uci show juliang_fastacl 2>/dev/null | grep -E "=ap|\.network=|\.ssid=|\.subnet=|\.node=" || true

echo
echo '[DONE] AX6000 WiFi detection fix installed.'
echo '[INFO] Read-only detector: juliang-fastacl wifi-detect'
echo '[INFO] Safe discovery:      juliang-fastacl discover'
echo '[INFO] Intentional shrink:  juliang-fastacl discover-force'
echo '[INFO] Refresh FastACL page after this script finishes.'
