#!/bin/sh
set -eu

CTRL="/usr/lib/lua/luci/controller/juliang_operator.lua"
VIEW="/usr/lib/lua/luci/view/juliang_operator/wireless.htm"
BK="/etc/juliang-fastacl/wireless-readonly-backup-$(date +%Y%m%d-%H%M%S)"
AUDIT="/tmp/juliang-fastacl-wireless-readonly-audit.log"

mkdir -p "$BK"
[ -f "$CTRL" ] && cp -af "$CTRL" "$BK/" || true
[ -f "$VIEW" ] && cp -af "$VIEW" "$BK/" || true
[ -f /etc/config/juliang_ssid_preserve ] && cp -af /etc/config/juliang_ssid_preserve "$BK/" || true
[ -f /usr/bin/juliang-fastacl-ssid-preserve ] && cp -af /usr/bin/juliang-fastacl-ssid-preserve "$BK/" || true
[ -f /etc/init.d/juliang-ssid-preserve ] && cp -af /etc/init.d/juliang-ssid-preserve "$BK/" || true

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

[ -s "$CTRL" ] || { echo "[ERROR] controller missing: $CTRL" >&2; exit 1; }
command -v lua >/dev/null 2>&1 || { echo "[ERROR] lua not found" >&2; exit 1; }

# Replace the whole wireless write API with a strictly read-only API.
CTRL="$CTRL" lua <<'LUA'
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
    -- Never set/commit/reload wireless here. Wireless SSID/password/hidden/
    -- channel/disabled state belongs exclusively to the system wireless UI.
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
        message="FastACL wireless is read-only; change SSID/password/hidden/channel in the system wireless page"
    })
end]=]

local out = s:sub(1, a - 1) .. readonly .. s:sub(b)
local tmp = path .. ".readonly.tmp"
local w = assert(io.open(tmp, "w"))
w:write(out)
w:close()
assert(os.rename(tmp, path))
LUA

lua -e "assert(loadfile('$CTRL'))"

# Make the UI clearly read-only. API enforcement above remains authoritative.
if [ -s "$VIEW" ]; then
    sed -i 's/<h2>无线设置<\/h2>/<h2>无线状态（FastACL 只读）<\/h2><div class="jow-note">SSID、密码、隐藏状态、信道请在系统原生无线页面修改；FastACL 这里只读取。<\/div>/' "$VIEW" || true
    sed -i 's/id="jow_all_visibility"[^>]*value="一键隐藏全部"[^>]*onclick="toggleAllVisibility()"/disabled="disabled" value="FastACL只读"/' "$VIEW" || true
fi

# Clear LuCI caches. No wifi reload is performed by this hotfix.
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

# Verify no FastACL boot/runtime component can write wireless.
: > "$AUDIT"
for p in \
    /etc/init.d/juliang-fastacl \
    /etc/hotplug.d/iface/99-juliang-fastacl \
    /usr/bin/juliang-fastacl \
    /usr/bin/juliang-fastacl-guard \
    /usr/bin/juliang-fastacl-mode \
    /usr/bin/juliang-fastacl-wifi-detect \
    /usr/libexec/juliang-fastacl-discover.lua \
    /usr/lib/lua/luci/controller/juliang_fastacl.lua \
    /usr/lib/lua/luci/controller/juliang_operator.lua; do
    [ -f "$p" ] || continue
    grep -nE 'uci[ :.-]*(set|add|delete).*wireless|uci:set\("wireless"|uci:commit\("wireless"|wifi[[:space:]]+reload' "$p" 2>/dev/null \
        | sed "s#^#$p:#" >> "$AUDIT" || true
done

if [ -s "$AUDIT" ]; then
    echo "[ERROR] FastACL wireless write path still detected:" >&2
    cat "$AUDIT" >&2
    echo "[ROLLBACK] restoring controller/view" >&2
    [ -f "$BK/$(basename "$CTRL")" ] && cp -af "$BK/$(basename "$CTRL")" "$CTRL" || true
    [ -f "$BK/$(basename "$VIEW")" ] && cp -af "$BK/$(basename "$VIEW")" "$VIEW" || true
    exit 2
fi

echo "[OK] removed SSID/hidden persistence workaround"
echo "[OK] FastACL wireless API is now READ ONLY"
echo "[OK] FastACL boot/runtime wireless write audit: clean"
echo "[OK] No wifi reload was triggered"
echo
echo "[INFO] From now on, change SSID/password/hidden/channel only in the system wireless page."
echo "[INFO] FastACL will read the current wireless names/networks dynamically."
echo "[INFO] backup: $BK"
