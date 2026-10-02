#!/bin/sh
set -eu

CORE_PIN="2049b19f87b7832d1d40edd7798001024ae91bc2"
PW2_PIN="bf711402f7fbedacdcd806e5f5d513fa68b3ed7f"
TMP="/tmp/jfa239-sb112-$$"
BACKUP="/etc/juliang-fastacl/sb112-backup-$(date +%Y%m%d-%H%M%S)"

cleanup() {
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

fetch() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fL --connect-timeout 8 --max-time 240 --retry 3 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    echo "[ERROR] curl/wget not found" >&2
    exit 1
  fi
}

echo "=================================================="
echo " JuLiang FastACL 2.3.9 Stable Runtime Repair"
echo " sing-box 1.12+ domain resolver migration"
echo " + PassWall2 SK5/HTTP import repair"
echo " Existing OpenWrt system / NO firmware flashing"
echo "=================================================="

command -v lua >/dev/null 2>&1 || {
  echo "[ERROR] lua not found" >&2
  exit 1
}
command -v sing-box >/dev/null 2>&1 || {
  echo "[ERROR] sing-box not found" >&2
  exit 1
}
command -v nft >/dev/null 2>&1 || {
  echo "[ERROR] nft command not found; this repair is for the nft/fw4 FastACL build" >&2
  exit 1
}

mkdir -p "$TMP" "$BACKUP"

echo "[INFO] sing-box:"
sing-box version 2>/dev/null | head -n2 || true

# If the previous full installer already copied FastACL, keep it.
# Otherwise restore the pinned 2.3.9 Stable runtime profile.
if [ ! -x /usr/bin/juliang-fastacl ] || [ ! -s /usr/libexec/juliang-fastacl-router.lua ]; then
  echo "[INFO] FastACL runtime is incomplete; restoring pinned 2.3.9 Stable profile..."
  fetch "https://codeload.github.com/wangjontao/Actions-OpenWrt/tar.gz/$CORE_PIN" "$TMP/core.tar.gz"
  mkdir -p "$TMP/core"
  tar -xzf "$TMP/core.tar.gz" --strip-components=1 -C "$TMP/core"
  test -d "$TMP/core/profiles/fastacl-v9/root"
  cp -af "$TMP/core/profiles/fastacl-v9/root/." /
fi

for p in \
  /usr/libexec/juliang-fastacl-router.lua \
  /etc/config/juliang_fastacl
do
  [ -f "$p" ] || continue
  d="$BACKUP$(dirname "$p")"
  mkdir -p "$d"
  cp -af "$p" "$d/"
done

echo "[INFO] Patching FastACL router generator for sing-box 1.12+..."
lua <<'LUA'
local path = "/usr/libexec/juliang-fastacl-router.lua"

local f = assert(io.open(path, "rb"))
local s = f:read("*a")
f:close()

local marker = "default_domain_resolver = dns_servers[1] and dns_servers[1].tag or nil,"
if not s:find(marker, 1, true) then
  local old = [[  route = {
    rules = route_rules,
    final = "direct"
  }]]
  local new = [[  route = {
    default_domain_resolver = dns_servers[1] and dns_servers[1].tag or nil,
    rules = route_rules,
    final = "direct"
  }]]
  local a,b = s:find(old, 1, true)
  assert(a, "FastACL route{} anchor not found; unsupported router generator layout")
  s = s:sub(1,a-1) .. new .. s:sub(b+1)

  local w = assert(io.open(path, "wb"))
  w:write(s)
  w:close()
end

local vf = assert(io.open(path, "rb"))
local v = vf:read("*a")
vf:close()
assert(v:find(marker, 1, true), "default_domain_resolver patch verification failed")
print("[OK] FastACL router generator: route.default_domain_resolver installed")
LUA

chmod 0755 \
  /usr/bin/juliang-fastacl \
  /usr/bin/juliang-fastacl-guard \
  /usr/bin/juliang-fastacl-luci-install \
  /usr/bin/juliang-operator \
  /etc/init.d/juliang-fastacl \
  /etc/hotplug.d/iface/99-juliang-fastacl 2>/dev/null || true

echo "[INFO] Discovering current Wi-Fi/network topology..."
if ! /usr/bin/juliang-fastacl discover >/tmp/jfa239-discover.json 2>/tmp/jfa239-discover.log; then
  echo "[ERROR] discover failed:"
  cat /tmp/jfa239-discover.log 2>/dev/null || true
  exit 1
fi

echo "[INFO] Rebuilding FastACL dataplane..."
if ! /usr/bin/juliang-fastacl repair >/tmp/jfa239-repair.log 2>&1; then
  echo "[ERROR] FastACL repair failed:"
  cat /tmp/jfa239-repair.log 2>/dev/null || true
  [ -s /etc/juliang-fastacl/router.json ] && {
    echo
    echo "[INFO] sing-box config check:"
    sing-box check -c /etc/juliang-fastacl/router.json 2>&1 || true
  }
  exit 1
fi

/usr/bin/juliang-fastacl save-state >/dev/null 2>&1 || true

test -s /etc/juliang-fastacl/router.json
grep -q '"default_domain_resolver"' /etc/juliang-fastacl/router.json || {
  echo "[ERROR] generated router.json still has no default_domain_resolver" >&2
  exit 1
}

if ! sing-box check -c /etc/juliang-fastacl/router.json >/tmp/jfa239-singbox-check.log 2>&1; then
  echo "[ERROR] sing-box check failed:"
  cat /tmp/jfa239-singbox-check.log
  exit 1
fi
echo "[OK] sing-box check passed"

nft list table inet juliang_killswitch >/dev/null 2>&1 || {
  echo "[ERROR] juliang_killswitch missing" >&2
  exit 1
}
echo "[OK] FastACL kill-switch present"

echo "[INFO] Applying PassWall2 SK5/HTTP runtime import patch..."
fetch \
  "https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PW2_PIN/scripts/repair-passwall2-sk5-http.sh" \
  "$TMP/repair-passwall2-sk5-http.sh"
chmod +x "$TMP/repair-passwall2-sk5-http.sh"
sh "$TMP/repair-passwall2-sk5-http.sh"

echo
echo "================ FINAL STATUS ================"
/usr/bin/juliang-fastacl status || true
echo "=============================================="

if ! /usr/bin/juliang-fastacl status | grep -q '^router: running'; then
  echo "[ERROR] FastACL router is not running" >&2
  exit 1
fi

echo
echo "[OK] FastACL 2.3.9 runtime repair completed"
echo "[OK] sing-box 1.12+ default_domain_resolver fixed"
echo "[OK] PassWall2 SK5/SOCKS5/HTTP import fixed"
echo "[OK] Backup: $BACKUP"
