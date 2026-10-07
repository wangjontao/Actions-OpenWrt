#!/bin/sh
set -eu

# Integrated AX6000/S20L WiFi-discovery hotfix archive.
PIN="a1d41aa3e8f2fb16fcf667f34a5602c81344206a"
ARCHIVE="https://codeload.github.com/wangjontao/Actions-OpenWrt/tar.gz/$PIN"
TMP="/tmp/jfa242-full-$$"
TGZ="/tmp/jfa242-full-$$.tar.gz"
LOCK="/tmp/jfa242-install.lock"
BACKUP="/etc/juliang-fastacl/v2.4.2-full-backup-$(date +%Y%m%d-%H%M%S)"
MUTATED=0
HAD_FASTACL=0
FASTACL_ENABLED=0
FASTACL_RUNNING=0
PW2_ENABLED=0
PW2_RUNNING=0

fail() { echo "[ERROR] $*" >&2; exit 1; }

cleanup() {
  rm -rf "$TMP" "$TGZ" "$LOCK" 2>/dev/null || true
}

restore_runtime_state() {
  if [ -x /etc/init.d/passwall2 ]; then
    if [ "$PW2_ENABLED" = "1" ]; then /etc/init.d/passwall2 enable >/dev/null 2>&1 || true; else /etc/init.d/passwall2 disable >/dev/null 2>&1 || true; fi
    if [ "$PW2_RUNNING" = "1" ]; then /etc/init.d/passwall2 restart >/dev/null 2>&1 || /etc/init.d/passwall2 start >/dev/null 2>&1 || true; else /etc/init.d/passwall2 stop >/dev/null 2>&1 || true; fi
  fi
  if [ "$HAD_FASTACL" = "1" ] && [ -x /etc/init.d/juliang-fastacl ]; then
    if [ "$FASTACL_ENABLED" = "1" ]; then /etc/init.d/juliang-fastacl enable >/dev/null 2>&1 || true; else /etc/init.d/juliang-fastacl disable >/dev/null 2>&1 || true; fi
    if [ "$FASTACL_RUNNING" = "1" ]; then
      /etc/init.d/juliang-fastacl restart >/dev/null 2>&1 || true
      /usr/bin/juliang-fastacl repair >/dev/null 2>&1 || true
    else
      /etc/init.d/juliang-fastacl stop >/dev/null 2>&1 || true
    fi
  elif [ "$HAD_FASTACL" = "0" ]; then
    /etc/init.d/juliang-fastacl stop >/dev/null 2>&1 || true
    /etc/init.d/juliang-fastacl disable >/dev/null 2>&1 || true
    nft delete table inet juliang_fastacl >/dev/null 2>&1 || true
    nft delete table inet juliang_killswitch >/dev/null 2>&1 || true
    while ip rule del fwmark 0x66/0xff table 100 >/dev/null 2>&1; do :; done
    ip route flush table 100 >/dev/null 2>&1 || true
  fi
}

rollback() {
  echo "[ROLLBACK] restoring pre-install files and configuration..." >&2
  set +e
  if [ -s "$BACKUP/created.list" ]; then
    while IFS= read -r rel; do [ -n "$rel" ] && rm -f "/$rel"; done < "$BACKUP/created.list"
  fi
  [ -d "$BACKUP/root" ] && cp -af "$BACKUP/root/." /
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
  /etc/init.d/rpcd restart >/dev/null 2>&1 || true
  /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
  /etc/init.d/dropbear restart >/dev/null 2>&1 || true
  restore_runtime_state
  rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
  rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
  echo "[ROLLBACK] completed. Snapshot: $BACKUP" >&2
}

on_exit() {
  rc=$?
  trap - EXIT INT TERM
  if [ "$rc" -ne 0 ] && [ "$MUTATED" = "1" ]; then rollback || true; fi
  cleanup
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$LOCK" 2>/dev/null || fail "another FastACL 2.4.2 install is running"
mkdir -p "$TMP" "$BACKUP/root"
: > "$BACKUP/created.list"

echo "=================================================="
echo " JuLiang FastACL 2.4.2 Stable Full"
echo " AX6000/S20L WiFi-detect integrated"
echo " transactional installer / preflight / auto rollback"
echo "=================================================="

command -v lua >/dev/null 2>&1 || fail "lua not found"
command -v tar >/dev/null 2>&1 || fail "tar not found"
command -v nft >/dev/null 2>&1 || fail "nft not found; install nftables userspace before running this transactional installer"
command -v curl >/dev/null 2>&1 || fail "curl not found; install curl before running this transactional installer"

curl -4 --http1.1 -fL --connect-timeout 15 --max-time 180 --retry 5 --retry-delay 2 -o "$TGZ" "$ARCHIVE"
[ -s "$TGZ" ] || fail "archive download failed"
tar -xzf "$TGZ" -C "$TMP"

SRC="$(find "$TMP" -type d -path '*/profiles/fastacl-v9/root' | head -n1)"
PW2_FIX="$(find "$TMP" -type f -path '*/scripts/repair-passwall2-sk5-http-import.sh' | head -n1)"
IMPORT403_FIX="$(find "$TMP" -type f -path '*/scripts/repair-fastacl-console-import-403.sh' | head -n1)"
V24_UPGRADE="$(find "$TMP" -type f -path '*/scripts/upgrade-juliang-fastacl-v2.4.sh' | head -n1)"
[ -n "$SRC" ] && [ -d "$SRC" ] || fail "FastACL profile root not found"
[ -s "$PW2_FIX" ] || fail "PassWall2 import repair script missing"
[ -s "$IMPORT403_FIX" ] || fail "FastACL import-403 repair script missing"
[ -s "$V24_UPGRADE" ] || fail "FastACL 2.4 node manager upgrade script missing"
[ -s "$SRC/usr/bin/juliang-fastacl-wifi-detect" ] || fail "FastACL WiFi detector missing"
[ -s "$SRC/usr/libexec/juliang-fastacl-discover.lua" ] || fail "FastACL discoverer missing"

# -------------------- PRE-FLIGHT: NO SYSTEM MUTATION --------------------
echo "[PREFLIGHT] validating bundled shell/Lua/UI/WiFi discovery payloads..."
sh -n "$PW2_FIX"
sh -n "$IMPORT403_FIX"
sh -n "$V24_UPGRADE"
sh -n "$SRC/etc/uci-defaults/94-juliang-fastacl-v9"
sh -n "$SRC/etc/uci-defaults/97-juliang-operator-mode"
sh -n "$SRC/usr/bin/juliang-fastacl"
sh -n "$SRC/usr/bin/juliang-fastacl-guard"
sh -n "$SRC/usr/bin/juliang-fastacl-wifi-detect"
lua -e "assert(loadfile('$SRC/usr/libexec/juliang-fastacl-discover.lua'))"
lua -e "assert(loadfile('$SRC/usr/lib/lua/luci/controller/juliang_fastacl.lua'))"
grep -q 'PARTIAL_AP_READY' "$SRC/usr/libexec/juliang-fastacl-discover.lua"
grep -q 'local runtime_cmd = \[=\[' "$SRC/usr/libexec/juliang-fastacl-discover.lua"
grep -q 'Detected A-series SSIDs' "$SRC/usr/bin/juliang-fastacl-wifi-detect"
grep -q "x.open('POST',IMPORT_API,true)" "$SRC/usr/lib/lua/luci/view/juliang_fastacl/console.htm" || grep -q 'JuLiangTK: FastACL import GET csrf fix' "$SRC/usr/lib/lua/luci/view/juliang_fastacl/console.htm"
grep -q 'value="重命名"' "$SRC/www/luci-static/resources/juliang-fastacl-v24.js"
grep -q 'value="删除选中"' "$SRC/www/luci-static/resources/juliang-fastacl-v24.js"
[ "$(sed -n "s/.*option version '\([^']*\)'.*/\1/p" "$SRC/etc/config/juliang_fastacl")" = "2.4.2" ] || fail "profile version is not 2.4.2"

if [ -s /usr/share/passwall2/subscribe.lua ]; then
  echo "[PREFLIGHT] validating this router's PassWall2 subscribe.lua before touching system..."
  sh "$PW2_FIX" --check
fi

echo "[PREFLIGHT] all compatibility checks passed"

# Record service state before mutation.
if [ -x /usr/bin/juliang-fastacl ]; then HAD_FASTACL=1; fi
if [ -x /etc/init.d/juliang-fastacl ]; then
  /etc/init.d/juliang-fastacl enabled >/dev/null 2>&1 && FASTACL_ENABLED=1 || true
  /etc/init.d/juliang-fastacl running >/dev/null 2>&1 && FASTACL_RUNNING=1 || true
fi
if [ -x /etc/init.d/passwall2 ]; then
  /etc/init.d/passwall2 enabled >/dev/null 2>&1 && PW2_ENABLED=1 || true
  /etc/init.d/passwall2 running >/dev/null 2>&1 && PW2_RUNNING=1 || true
fi

backup_path() {
  p="$1"
  if [ -e "$p" ] || [ -L "$p" ]; then
    rel="${p#/}"
    mkdir -p "$BACKUP/root/$(dirname "$rel")"
    cp -af "$p" "$BACKUP/root/$rel"
  fi
}

# Back up every file the profile may replace; remember newly-created paths so
# a failed fresh install can remove them again.
find "$SRC" \( -type f -o -type l \) -print | while IFS= read -r srcf; do
  rel="${srcf#$SRC/}"
  if [ -e "/$rel" ] || [ -L "/$rel" ]; then
    mkdir -p "$BACKUP/root/$(dirname "$rel")"
    cp -af "/$rel" "$BACKUP/root/$rel"
  else
    echo "$rel" >> "$BACKUP/created.list"
  fi
done

# Files changed outside the profile tree must also be transactional.
for p in \
  /etc/config/firewall \
  /etc/config/passwall2 \
  /etc/config/juliang_fastacl \
  /etc/config/juliang_operator \
  /etc/config/dropbear \
  /etc/config/rpcd \
  /usr/share/passwall2/subscribe.lua; do
  backup_path "$p"
done

# -------------------- MUTATION STARTS HERE --------------------
MUTATED=1
cp -af "$SRC/." /

# On upgrades, restore the user's live FastACL configuration before migrations;
# v2.4.2 defaults only fill missing DNS/health preferences.
if [ -s "$BACKUP/root/etc/config/juliang_fastacl" ]; then
  cp -af "$BACKUP/root/etc/config/juliang_fastacl" /etc/config/juliang_fastacl
fi

chmod 0755 \
  /usr/bin/juliang-fastacl \
  /usr/bin/juliang-fastacl-guard \
  /usr/bin/juliang-fastacl-luci-install \
  /usr/bin/juliang-fastacl-wifi-detect \
  /usr/bin/uninstall-juliang-fastacl \
  /usr/bin/juliang-operator \
  /etc/init.d/juliang-fastacl \
  /etc/hotplug.d/iface/99-juliang-fastacl \
  /etc/uci-defaults/94-juliang-fastacl-v9 \
  /etc/uci-defaults/97-juliang-operator-mode

# Defer FastACL runtime start until all patches validate. This defaults script
# also integrates wifi-detect/discover-force into the main CLI idempotently.
JFA_DEFER_RUNTIME=1 sh /etc/uci-defaults/94-juliang-fastacl-v9
sh /etc/uci-defaults/97-juliang-operator-mode

# Console POST -> LuCI XHR.get CSRF-safe importer.
echo "[INFO] applying FastACL batch-import HTTP 403 fix..."
sh "$IMPORT403_FIX"

# PassWall2 SK5/HTTP backend. Preflight above guaranteed compatibility before
# any FastACL/firewall mutation occurred.
if [ -s /usr/share/passwall2/subscribe.lua ]; then
  echo "[INFO] applying PassWall2 SK5/HTTP v2.4.2 import support..."
  sh "$PW2_FIX"
fi

# Reuse the already-tested 2.4 node-manager backend patch, but feed it the JS
# bundled in this fixed archive instead of making a second network request.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/curl" <<'CURLWRAP'
#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 2
cp -af "$JFA_BUNDLED_JS" "$out"
CURLWRAP
chmod 0755 "$TMP/fakebin/curl"
JFA_BUNDLED_JS="$SRC/www/luci-static/resources/juliang-fastacl-v24.js" \
PATH="$TMP/fakebin:$PATH" sh "$V24_UPGRADE"

# V2.4.2 version stamp and cache-busting label.
uci set juliang_fastacl.main.version='2.4.2'
uci commit juliang_fastacl
sed -i 's/FastACL 2\.4 控制台/FastACL 2.4.2 控制台/g' /www/luci-static/resources/juliang-fastacl-v24.js
sed -i 's/juliang-fastacl-v24\.js?v=2401/juliang-fastacl-v24.js?v=2420/g' /usr/lib/lua/luci/view/juliang_fastacl/console.htm

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
/etc/init.d/dropbear restart >/dev/null 2>&1 || true

# Only now start/rebuild FastACL data plane. Capture the actual WiFi names first
# for diagnostics. Protected discover is allowed to refuse a partial scan on an
# upgrade; it must never erase an existing A1..A20 topology.
/etc/init.d/juliang-fastacl enable >/dev/null 2>&1 || true
/usr/bin/juliang-fastacl wifi-detect >/tmp/juliang-fastacl242-install-wifi-detect.log 2>&1 || true

DISC_RC=0
/usr/bin/juliang-fastacl discover >/tmp/juliang-fastacl242-install-discover.json 2>/tmp/juliang-fastacl242-install-discover.log || DISC_RC=$?
case "$DISC_RC" in
  0)
    echo "[INFO] WiFi discovery completed"
    ;;
  2|3)
    AP_COUNT="$(uci -q get juliang_fastacl.main.ap_count 2>/dev/null || echo 0)"
    case "$AP_COUNT" in ''|*[!0-9]*) AP_COUNT=0 ;; esac
    [ "$AP_COUNT" -gt 0 ] || fail "WiFi discovery is not ready and there is no previous AP topology to preserve"
    echo "[SAFE] partial WiFi scan refused; preserved existing $AP_COUNT AP slots"
    ;;
  *)
    fail "FastACL discover failed with rc=$DISC_RC; see /tmp/juliang-fastacl242-install-discover.log"
    ;;
esac

/usr/bin/juliang-fastacl repair >/tmp/juliang-fastacl242-install-repair.log 2>&1
/usr/bin/juliang-fastacl save-state >/dev/null 2>&1 || true

# -------------------- FINAL VALIDATION --------------------
[ "$(uci -q get juliang_fastacl.main.version || true)" = "2.4.2" ]
grep -q 'install_killswitch' /usr/bin/juliang-fastacl
grep -q 'move_node(){' /usr/bin/juliang-fastacl
grep -q 'wifi-detect)' /usr/bin/juliang-fastacl
grep -q 'discover-force)' /usr/bin/juliang-fastacl
grep -q 'enforce_failclosed_firewall' /usr/bin/juliang-fastacl-guard
[ -x /usr/bin/juliang-fastacl-wifi-detect ]
lua -e "assert(loadfile('/usr/libexec/juliang-fastacl-discover.lua'))"
grep -q 'PARTIAL_AP_READY' /usr/libexec/juliang-fastacl-discover.lua
grep -q 'local runtime_cmd = \[=\[' /usr/libexec/juliang-fastacl-discover.lua
nft list table inet juliang_killswitch >/dev/null 2>&1
/usr/bin/juliang-fastacl status | grep -q '^router: running'

grep -q 'FastACL 2.4 node admin backend fix1' /usr/lib/lua/luci/controller/juliang_fastacl.lua
grep -q 'juliang-fastacl-v24.js?v=2420' /usr/lib/lua/luci/view/juliang_fastacl/console.htm
grep -q 'FastACL 2.4.2 控制台' /www/luci-static/resources/juliang-fastacl-v24.js
grep -q 'value="重命名"' /www/luci-static/resources/juliang-fastacl-v24.js
grep -q 'value="删除"' /www/luci-static/resources/juliang-fastacl-v24.js
grep -q 'value="删除选中"' /www/luci-static/resources/juliang-fastacl-v24.js

grep -q 'JuLiangTK: FastACL import GET csrf fix' /usr/lib/lua/luci/view/juliang_fastacl/console.htm
grep -q 'XHR.get(IMPORT_API,params' /usr/lib/lua/luci/view/juliang_fastacl/console.htm
! grep -q "x.open('POST',IMPORT_API,true)" /usr/lib/lua/luci/view/juliang_fastacl/console.htm

if [ -s /usr/share/passwall2/subscribe.lua ]; then
  lua -e "assert(loadfile('/usr/share/passwall2/subscribe.lua'))"
  grep -q 'PassWall2 SK5 HTTP runtime import v2.4.2' /usr/share/passwall2/subscribe.lua
  grep -q 'provider shorthand + sk5 alias v2.4.2' /usr/share/passwall2/subscribe.lua
fi

DROP_OK=0
for sec in $(uci -q show dropbear 2>/dev/null | sed -n "s/^dropbear\.\([^.=]*\)=dropbear$/\1/p"); do
  [ "$(uci -q get dropbear.$sec.Port || true)" = "20022" ] && DROP_OK=1
done
[ "$DROP_OK" = "1" ]

echo
echo "[OK] JuLiang FastACL 2.4.2 Stable Full installed"
echo "[OK] AX6000/S20L runtime WiFi-name detector integrated"
echo "[OK] A1-A20 -> a1-a20 fallback + partial-scan protection integrated"
echo "[OK] Lua 5.1 long-string compatibility validated before mutation"
echo "[OK] wifi-detect / discover / discover-force CLI integrated"
echo "[OK] SK5 four-part URI + bare shorthand + standard URI import fixed"
echo "[OK] PassWall2 compatibility was checked before system mutation"
echo "[OK] Existing FastACL DNS/health preferences preserved when present"
echo "[OK] Firewall/PassWall2/FastACL/UI files covered by automatic rollback"
echo "[OK] Rename / single delete / checkbox batch delete retained"
echo "[OK] Batch-import HTTP 403 fix retained"
echo "[OK] SSH port: 20022"
echo "[INFO] WiFi detection log: /tmp/juliang-fastacl242-install-wifi-detect.log"
echo "[INFO] rollback snapshot: $BACKUP"
