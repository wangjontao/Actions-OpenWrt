#!/bin/sh
set -eu

CTRL_LUA="/usr/lib/lua/luci/controller/juliang_operator.lua"
CTRL_UCODE="/usr/share/ucode/luci/controller/juliang_operator.uc"
VIEW="/usr/lib/lua/luci/view/juliang_operator/wireless.htm"
BK="/etc/juliang-fastacl/wireless-readonly-backup-$(date +%Y%m%d-%H%M%S)"
AUDIT="/tmp/juliang-fastacl-wireless-readonly-audit.log"

mkdir -p "$BK"
for p in "$CTRL_LUA" "$CTRL_UCODE" "$VIEW" \
    /etc/config/juliang_ssid_preserve \
    /usr/bin/juliang-fastacl-ssid-preserve \
    /etc/init.d/juliang-ssid-preserve; do
    [ -f "$p" ] && cp -af "$p" "$BK/$(basename "$p")" || true
done

echo "=================================================="
echo " FastACL 2.4.2 Wireless Read-Only Hotfix"
echo " FastACL reads wireless; it never writes wireless"
echo "=================================================="
echo "[INFO] backup: $BK"

# Remove the temporary SSID/hidden persistence workaround completely.
if [ -x /etc/init.d/juliang-ssid-preserve ]; then
    /etc/init.d/juliang-ssid-preserve stop >/dev/null 2>&1 || true
    /etc/init.d/juliang-ssid-preserve disable >/dev/null 2>&1 || true
fi
rm -f /etc/rc.d/S*juliang-ssid-preserve 2>/dev/null || true
rm -f /etc/init.d/juliang-ssid-preserve
rm -f /usr/bin/juliang-fastacl-ssid-preserve
rm -f /etc/config/juliang_ssid_preserve
rm -f /tmp/juliang-ssid-preserve* /tmp/juliang-fastacl/ssid-* 2>/dev/null || true

echo "[OK] removed legacy SSID/hidden persistence workaround"

# Lua LuCI builds: replace the operator wireless write API with a strict
# read-only API. Some images do not ship this controller at all; that is valid
# and must not make the hotfix fail.
if [ -s "$CTRL_LUA" ]; then
    command -v lua >/dev/null 2>&1 || { echo "[ERROR] lua controller exists but lua is missing" >&2; exit 1; }

    CTRL="$CTRL_LUA" lua <<'LUA'
local path = assert(os.getenv("CTRL"))
local f = assert(io.open(path, "r"))
local s = f:read("*a")
f:close()

local a = assert(s:find("function handle_wireless()", 1, true), "handle_wireless start not found")
local b = assert(s:find("\n\nfunction handle_dashboard()", a, true), "handle_dashboard anchor not found")

local readonly = [=[function handle_wireless()
    local http = require "luci.http"
    local uci = require("uci").cursor()
    local action = http.formvalue("action") or "status"

    -- FastACL 2.4.2 wireless contract: READ ONLY.
    -- Wireless SSID/password/hidden/channel/disabled are owned by OpenWrt.
    if action == "status" then
        local devices, ifaces = wifi_status(uci)
        write_json({ok=true, readonly=true, devices=devices, ifaces=ifaces})
        return
    end

    if action == "clients" then
        write_json({ok=true, readonly=true, groups=wireless_clients(uci), timestamp=os.time()})
        return
    end

    write_json({
        ok=false,
        readonly=true,
        error="READ_ONLY",
        message="FastACL wireless is read-only; change wireless settings in the system wireless page"
    })
end]=]

local out = s:sub(1, a - 1) .. readonly .. s:sub(b)
local tmp = path .. ".readonly.tmp"
local w = assert(io.open(tmp, "w"))
w:write(out)
w:close()
assert(os.rename(tmp, path))
LUA

    lua -e "assert(loadfile('$CTRL_LUA'))"
    echo "[OK] Lua Operator wireless API locked READ ONLY"
elif [ -s "$CTRL_UCODE" ]; then
    # Do not blindly rewrite ucode. The audit below will reject the build if
    # this controller contains a wireless write path.
    echo "[INFO] ucode Operator controller detected; write-path audit will verify it"
else
    echo "[INFO] Operator wireless controller not installed on this image; API patch skipped"
fi

# Make the legacy Lua view clearly read-only when it exists. API enforcement
# remains authoritative. Missing view is valid on images without Operator UI.
if [ -s "$VIEW" ]; then
    sed -i 's/<h2>无线设置<\/h2>/<h2>无线状态（FastACL 只读）<\/h2><div class="jow-note">SSID、密码、隐藏状态、信道请在系统原生无线页面修改；FastACL 这里只读取。<\/div>/' "$VIEW" || true
fi

# Verify no FastACL boot/runtime component can write wireless. Files that do
# not exist on a particular image are simply skipped.
: > "$AUDIT"
for p in \
    /etc/init.d/juliang-fastacl \
    /etc/hotplug.d/iface/99-juliang-fastacl \
    /usr/bin/juliang-fastacl \
    /usr/bin/juliang-fastacl-guard \
    /usr/bin/juliang-fastacl-mode \
    /usr/bin/juliang-fastacl-wifi-detect \
    /usr/bin/juliang-fastacl-wireless-readonly \
    /usr/libexec/juliang-fastacl-discover.lua \
    /usr/lib/lua/luci/controller/juliang_fastacl.lua \
    "$CTRL_LUA" \
    "$CTRL_UCODE"; do
    [ -f "$p" ] || continue
    grep -nE 'uci[ :.-]*(set|add|delete).*wireless|uci:set\("wireless"|uci:commit\("wireless"|wifi[[:space:]]+reload|ubus[[:space:]].*wireless.*(set|down|up)' "$p" 2>/dev/null \
        | sed "s#^#$p:#" >> "$AUDIT" || true
done

if [ -s "$AUDIT" ]; then
    echo "[ERROR] FastACL wireless write path still detected:" >&2
    cat "$AUDIT" >&2
    echo "[INFO] Nothing in /etc/config/wireless was modified by this hotfix." >&2
    exit 2
fi

# Clear LuCI caches only. Deliberately do NOT call wifi reload/restart.
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] FastACL boot/runtime wireless write audit: clean"
echo "[OK] FastACL wireless contract: READ ONLY"
echo "[OK] No wifi reload/restart was triggered"
echo
echo "[INFO] Change SSID/password/hidden/channel only in the system wireless page."
echo "[INFO] FastACL only reads the current wireless topology and clients."
echo "[INFO] backup: $BK"
