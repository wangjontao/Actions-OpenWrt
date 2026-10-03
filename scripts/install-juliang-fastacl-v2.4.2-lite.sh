#!/bin/sh
set -eu

REPO="wangjontao/Actions-OpenWrt"
PAYLOAD_PIN="8551eb4a4cd7f796713c35a56c281767affb299a"
API_BASE="https://api.github.com/repos/$REPO/contents"
TMP="/tmp/jfa242-lite-$$"
STAGE="$TMP/root"
TOOLS="$TMP/tools"
LOCK="/tmp/jfa242-lite.lock"
BACKUP="/etc/juliang-fastacl/v2.4.2-lite-backup-$(date +%Y%m%d-%H%M%S)"
MANIFEST="$TMP/profile.list"
MUTATED=0
HAD_FASTACL=0
FASTACL_ENABLED=0
FASTACL_RUNNING=0
PW2_ENABLED=0
PW2_RUNNING=0

fail() { echo "[ERROR] $*" >&2; exit 1; }

cleanup() {
  rm -rf "$TMP" "$LOCK" 2>/dev/null || true
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

mkdir "$LOCK" 2>/dev/null || fail "another FastACL 2.4.2 Lite install is running"
mkdir -p "$STAGE" "$TOOLS" "$BACKUP/root"
: > "$BACKUP/created.list"

cat > "$MANIFEST" <<'EOF'
etc/config/juliang_fastacl
etc/hotplug.d/iface/99-juliang-fastacl
etc/init.d/juliang-fastacl
etc/uci-defaults/94-juliang-fastacl-v9
etc/uci-defaults/97-juliang-operator-mode
usr/bin/juliang-fastacl
usr/bin/juliang-fastacl-guard
usr/bin/juliang-fastacl-luci-install
usr/bin/juliang-operator
usr/bin/uninstall-juliang-fastacl
usr/lib/lua/luci/controller/juliang_fastacl.lua
usr/lib/lua/luci/controller/juliang_operator.lua
usr/lib/lua/luci/view/juliang_fastacl/console.htm
usr/lib/lua/luci/view/juliang_operator/home.htm
usr/lib/lua/luci/view/juliang_operator/wireless.htm
usr/libexec/juliang-fastacl-discover.lua
usr/libexec/juliang-fastacl-relay.lua
usr/libexec/juliang-fastacl-router.lua
usr/libexec/juliang-operator-patch.lua
usr/share/luci/menu.d/zz-juliang-operator.json
usr/share/rpcd/acl.d/juliang-operator.json
www/luci-static/resources/juliang-fastacl-v24.js
EOF

echo "=================================================="
echo " JuLiang FastACL 2.4.2 Lite"
echo " lightweight / transactional / preflight / rollback"
echo " only downloads required FastACL files (~200-250 KB payload)"
echo "=================================================="

command -v lua >/dev/null 2>&1 || fail "lua not found"
command -v nft >/dev/null 2>&1 || fail "nft not found; install nftables userspace first"
command -v curl >/dev/null 2>&1 || fail "curl not found; install curl first"

api_get() {
  repo_path="$1"
  out="$2"
  mkdir -p "$(dirname "$out")"
  echo "[GET] $repo_path"
  curl -4 --http1.1 -fsSL \
    --connect-timeout 15 --max-time 90 \
    --retry 5 --retry-delay 1 \
    -H 'Accept: application/vnd.github.raw+json' \
    -H 'User-Agent: FastACL-2.4.2-Lite' \
    -o "$out" \
    "$API_BASE/$repo_path?ref=$PAYLOAD_PIN"
  [ -s "$out" ] || fail "downloaded file is empty: $repo_path"
}

# Download only the FastACL profile files required by this installer.
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  api_get "profiles/fastacl-v9/root/$rel" "$STAGE/$rel"
done < "$MANIFEST"

api_get "scripts/repair-passwall2-sk5-http-import.sh" "$TOOLS/repair-passwall2-sk5-http-import.sh"
api_get "scripts/repair-fastacl-console-import-403.sh" "$TOOLS/repair-fastacl-console-import-403.sh"
api_get "scripts/upgrade-juliang-fastacl-v2.4.sh" "$TOOLS/upgrade-juliang-fastacl-v2.4.sh"

PW2_FIX="$TOOLS/repair-passwall2-sk5-http-import.sh"
IMPORT403_FIX="$TOOLS/repair-fastacl-console-import-403.sh"
V24_UPGRADE="$TOOLS/upgrade-juliang-fastacl-v2.4.sh"

# -------------------- PRE-FLIGHT: NO SYSTEM MUTATION --------------------
echo "[PREFLIGHT] validating downloaded shell/Lua/UI payloads..."
sh -n "$PW2_FIX"
sh -n "$IMPORT403_FIX"
sh -n "$V24_UPGRADE"
sh -n "$STAGE/etc/uci-defaults/94-juliang-fastacl-v9"
sh -n "$STAGE/etc/uci-defaults/97-juliang-operator-mode"
sh -n "$STAGE/usr/bin/juliang-fastacl"
sh -n "$STAGE/usr/bin/juliang-fastacl-guard"
sh -n "$STAGE/usr/bin/juliang-fastacl-luci-install"
sh -n "$STAGE/usr/bin/juliang-operator"
sh -n "$STAGE/usr/bin/uninstall-juliang-fastacl"
lua -e "assert(loadfile('$STAGE/usr/lib/lua/luci/controller/juliang_fastacl.lua'))"
lua -e "assert(loadfile('$STAGE/usr/lib/lua/luci/controller/juliang_operator.lua'))"
lua -e "assert(loadfile('$STAGE/usr/libexec/juliang-fastacl-discover.lua'))"
lua -e "assert(loadfile('$STAGE/usr/libexec/juliang-fastacl-relay.lua'))"
lua -e "assert(loadfile('$STAGE/usr/libexec/juliang-fastacl-router.lua'))"
lua -e "assert(loadfile('$STAGE/usr/libexec/juliang-operator-patch.lua'))"
grep -q 'value="重命名"' "$STAGE/www/luci-static/resources/juliang-fastacl-v24.js"
grep -q 'value="删除选中"' "$STAGE/www/luci-static/resources/juliang-fastacl-v24.js"
[ "$(sed -n "s/.*option version '\([^']*\)'.*/\1/p" "$STAGE/etc/config/juliang_fastacl")" = "2.4.2" ] || fail "profile version is not 2.4.2"

if [ -s /usr/share/passwall2/subscribe.lua ]; then
  echo "[PREFLIGHT] validating this router's PassWall2 subscribe.lua..."
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

# Back up each profile destination; record paths that did not exist before.
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ -e "/$rel" ] || [ -L "/$rel" ]; then
    backup_path "/$rel"
  else
    echo "$rel" >> "$BACKUP/created.list"
  fi
done < "$MANIFEST"

# Files changed outside the downloaded profile must also be transactional.
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
cp -af "$STAGE/." /

# Preserve the live FastACL configuration on upgrades. V2.4.2 defaults only
# fill missing DNS/health preferences instead of overwriting user tuning.
if [ -s "$BACKUP/root/etc/config/juliang_fastacl" ]; then
  cp -af "$BACKUP/root/etc/config/juliang_fastacl" /etc/config/juliang_fastacl
fi

chmod 0755 \
  /usr/bin/juliang-fastacl \
  /usr/bin/juliang-fastacl-guard \
  /usr/bin/juliang-fastacl-luci-install \
  /usr/bin/uninstall-juliang-fastacl \
  /usr/bin/juliang-operator \
  /etc/init.d/juliang-fastacl \
  /etc/hotplug.d/iface/99-juliang-fastacl \
  /etc/uci-defaults/94-juliang-fastacl-v9 \
  /etc/uci-defaults/97-juliang-operator-mode

# Do not start FastACL until all UI/import patches have validated.
JFA_DEFER_RUNTIME=1 sh /etc/uci-defaults/94-juliang-fastacl-v9
sh /etc/uci-defaults/97-juliang-operator-mode

echo "[INFO] applying FastACL batch-import HTTP 403 fix..."
sh "$IMPORT403_FIX"

if [ -s /usr/share/passwall2/subscribe.lua ]; then
  echo "[INFO] applying PassWall2 SK5/HTTP v2.4.2 import support..."
  sh "$PW2_FIX"
fi

# The tested 2.4 node-manager upgrader normally downloads its JS. Feed it the
# already-downloaded bundled JS so Lite performs no extra payload download.
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
JFA_BUNDLED_JS="$STAGE/www/luci-static/resources/juliang-fastacl-v24.js" \
PATH="$TMP/fakebin:$PATH" sh "$V24_UPGRADE"

uci set juliang_fastacl.main.version='2.4.2'
uci commit juliang_fastacl
sed -i 's/FastACL 2\.4 控制台/FastACL 2.4.2 控制台/g' /www/luci-static/resources/juliang-fastacl-v24.js
sed -i 's/juliang-fastacl-v24\.js?v=2401/juliang-fastacl-v24.js?v=2421/g' /usr/lib/lua/luci/view/juliang_fastacl/console.htm

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
/etc/init.d/dropbear restart >/dev/null 2>&1 || true

# Start/rebuild FastACL only after every patch is in place.
/etc/init.d/juliang-fastacl enable >/dev/null 2>&1 || true
/usr/bin/juliang-fastacl discover >/tmp/juliang-fastacl242-lite-discover.json 2>/tmp/juliang-fastacl242-lite-discover.log
/usr/bin/juliang-fastacl repair >/tmp/juliang-fastacl242-lite-repair.log 2>&1
/usr/bin/juliang-fastacl save-state >/dev/null 2>&1 || true

# -------------------- FINAL VALIDATION --------------------
[ "$(uci -q get juliang_fastacl.main.version || true)" = "2.4.2" ]
grep -q 'install_killswitch' /usr/bin/juliang-fastacl
grep -q 'move_node(){' /usr/bin/juliang-fastacl
grep -q 'enforce_failclosed_firewall' /usr/bin/juliang-fastacl-guard
nft list table inet juliang_killswitch >/dev/null 2>&1
/usr/bin/juliang-fastacl status | grep -q '^router: running'

grep -q 'FastACL 2.4 node admin backend fix1' /usr/lib/lua/luci/controller/juliang_fastacl.lua
grep -q 'juliang-fastacl-v24.js?v=2421' /usr/lib/lua/luci/view/juliang_fastacl/console.htm
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
[ "$DROP_OK" = "1" ] || fail "SSH 20022 validation failed"

echo
echo "[OK] JuLiang FastACL 2.4.2 Lite installed"
echo "[OK] downloaded only required FastACL payload files; no 34MB repository archive"
echo "[OK] SK5/SOCKS5/SOCKS/HTTP shorthand + sk5://host:port:user:pass"
echo "[OK] import HTTP 403 fix"
echo "[OK] rename / single delete / checkbox batch delete"
echo "[OK] settings-preserving defaults + transactional rollback"
echo "[OK] backup: $BACKUP"
echo "[INFO] refresh LuCI with Ctrl+F5"
