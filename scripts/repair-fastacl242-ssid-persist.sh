#!/bin/sh
set -eu

STATE_CFG="juliang_ssid_preserve"
STATE_FILE="/etc/config/$STATE_CFG"
CLI="/usr/bin/juliang-fastacl-ssid-preserve"
INIT="/etc/init.d/juliang-ssid-preserve"
CTRL="/usr/lib/lua/luci/controller/juliang_operator.lua"
BK="/etc/juliang-fastacl/ssid-preserve-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BK"
[ -f "$STATE_FILE" ] && cp -af "$STATE_FILE" "$BK/" || true
[ -f "$CLI" ] && cp -af "$CLI" "$BK/" || true
[ -f "$INIT" ] && cp -af "$INIT" "$BK/" || true
[ -f "$CTRL" ] && cp -af "$CTRL" "$BK/" || true

echo "=================================================="
echo " FastACL 2.4.2 Wireless Persist Hotfix"
echo " Preserve tk1-tk20 SSID + hidden state across reboot"
echo "=================================================="
echo "[INFO] backup: $BK"

cat > "$CLI" <<'EOF'
#!/bin/sh
set -u
CFG="juliang_ssid_preserve"
LOG="/tmp/juliang-ssid-preserve.log"

log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

is_managed_section(){
    case "${1:-}" in
        tk[1-9]|tk1[0-9]|tk20) return 0 ;;
        *) return 1 ;;
    esac
}

norm_hidden(){
    case "${1:-0}" in
        1|on|true|yes) echo 1 ;;
        *) echo 0 ;;
    esac
}

save_state(){
    tmp="/tmp/${CFG}.$$"
    : > "$tmp"
    found=0

    for sec in $(uci -q show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p"); do
        is_managed_section "$sec" || continue
        [ "$(uci -q get wireless.$sec.mode 2>/dev/null || echo ap)" = "ap" ] || continue
        ssid="$(uci -q get wireless.$sec.ssid 2>/dev/null || true)"
        [ -n "$ssid" ] || continue
        hidden="$(norm_hidden "$(uci -q get wireless.$sec.hidden 2>/dev/null || echo 0)")"

        printf "config ssid '%s'\n" "$sec" >> "$tmp"
        esc="$(printf '%s' "$ssid" | sed "s/'/'\\''/g")"
        printf "\toption section '%s'\n" "$sec" >> "$tmp"
        printf "\toption ssid '%s'\n" "$esc" >> "$tmp"
        printf "\toption hidden '%s'\n\n" "$hidden" >> "$tmp"
        found=$((found+1))
    done

    [ "$found" -gt 0 ] || {
        rm -f "$tmp"
        echo "[ERROR] no tk1-tk20 wireless sections found" >&2
        return 2
    }

    mv "$tmp" "/etc/config/$CFG"
    log "saved $found wireless profile(s): SSID + hidden"
    echo "[OK] saved $found wireless profile(s): SSID + hidden"
}

restore_state(){
    [ -s "/etc/config/$CFG" ] || {
        echo "[WARN] no saved wireless state"
        return 0
    }

    changed=0
    restored_ssid=0
    restored_hidden=0

    for sec in $(uci -q show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\([^.=]*\)=ssid$/\1/p"); do
        is_managed_section "$sec" || continue
        [ "$(uci -q get wireless.$sec 2>/dev/null || true)" = "wifi-iface" ] || continue

        wanted_ssid="$(uci -q get $CFG.$sec.ssid 2>/dev/null || true)"
        wanted_hidden="$(norm_hidden "$(uci -q get $CFG.$sec.hidden 2>/dev/null || echo 0)")"

        current_ssid="$(uci -q get wireless.$sec.ssid 2>/dev/null || true)"
        current_hidden="$(norm_hidden "$(uci -q get wireless.$sec.hidden 2>/dev/null || echo 0)")"

        if [ -n "$wanted_ssid" ] && [ "$current_ssid" != "$wanted_ssid" ]; then
            uci set wireless.$sec.ssid="$wanted_ssid"
            changed=1
            restored_ssid=$((restored_ssid+1))
            log "restore ssid $sec: '$current_ssid' -> '$wanted_ssid'"
        fi

        if [ "$current_hidden" != "$wanted_hidden" ]; then
            uci set wireless.$sec.hidden="$wanted_hidden"
            changed=1
            restored_hidden=$((restored_hidden+1))
            log "restore hidden $sec: '$current_hidden' -> '$wanted_hidden'"
        fi
    done

    if [ "$changed" -eq 1 ]; then
        uci commit wireless
        wifi reload >/tmp/juliang-ssid-preserve-wifi.log 2>&1 || true
        echo "[OK] restored SSID=$restored_ssid hidden=$restored_hidden and reloaded WiFi"
    else
        echo "[OK] SSID/hidden already match saved state"
    fi
}

status_state(){
    printf "%-8s %-24s %-8s %-24s %-8s\n" SECTION CURRENT_SSID CUR_HID SAVED_SSID SAV_HID
    printf "%-8s %-24s %-8s %-24s %-8s\n" ------- ------------------------ ------- ------------------------ -------
    for sec in tk1 tk2 tk3 tk4 tk5 tk6 tk7 tk8 tk9 tk10 tk11 tk12 tk13 tk14 tk15 tk16 tk17 tk18 tk19 tk20; do
        [ "$(uci -q get wireless.$sec 2>/dev/null || true)" = "wifi-iface" ] || continue
        cur_ssid="$(uci -q get wireless.$sec.ssid 2>/dev/null || true)"
        cur_hidden="$(norm_hidden "$(uci -q get wireless.$sec.hidden 2>/dev/null || echo 0)")"
        sav_ssid="$(uci -q get $CFG.$sec.ssid 2>/dev/null || true)"
        sav_hidden="$(norm_hidden "$(uci -q get $CFG.$sec.hidden 2>/dev/null || echo 0)")"
        printf "%-8s %-24s %-8s %-24s %-8s\n" "$sec" "$cur_ssid" "$cur_hidden" "$sav_ssid" "$sav_hidden"
    done
}

case "${1:-}" in
    save) save_state ;;
    restore) restore_state ;;
    status) status_state ;;
    *) echo "Usage: juliang-fastacl-ssid-preserve {save|restore|status}"; exit 1 ;;
esac
EOF
chmod 0755 "$CLI"

cat > "$INIT" <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=01

start_service() {
    [ -s /etc/config/juliang_ssid_preserve ] || return 0
    procd_open_instance
    procd_set_param command /bin/sh -c '
        mkdir -p /tmp/juliang-fastacl
        sleep 8
        /usr/bin/juliang-fastacl-ssid-preserve restore >>/tmp/juliang-ssid-preserve-boot.log 2>&1
        sleep 12
        /usr/bin/juliang-fastacl-ssid-preserve restore >>/tmp/juliang-ssid-preserve-boot.log 2>&1
        sleep 25
        /usr/bin/juliang-fastacl-ssid-preserve restore >>/tmp/juliang-ssid-preserve-boot.log 2>&1
    '
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
chmod 0755 "$INIT"

# Every operator-page wireless commit (SSID edit or hide/show action) refreshes
# the saved persistent state. Older installed hotfixes already have this marker.
if [ -s "$CTRL" ] && grep -q 'uci:commit("wireless")' "$CTRL" && ! grep -q 'JFA_SSID_PRESERVE' "$CTRL"; then
    sed -i '/uci:commit("wireless")/a\    require("luci.sys").call("/usr/bin/juliang-fastacl-ssid-preserve save >/dev/null 2>&1") -- JFA_SSID_PRESERVE' "$CTRL"
    if command -v lua >/dev/null 2>&1; then
        lua -e "assert(loadfile('$CTRL'))" || {
            echo "[ERROR] controller syntax failed; restoring backup" >&2
            cp -af "$BK/$(basename "$CTRL")" "$CTRL" 2>/dev/null || true
            exit 1
        }
    fi
fi

# Capture CURRENT names and CURRENT hidden flags before enabling boot restore.
"$CLI" save

/etc/init.d/juliang-ssid-preserve enable >/dev/null 2>&1 || true
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

echo
echo "===== Saved wireless state ====="
"$CLI" status

echo
echo "[DONE] wireless persist hotfix installed"
echo "[INFO] Boot restore service: /etc/init.d/juliang-ssid-preserve"
echo "[INFO] hidden: 1=隐藏, 0=显示"
echo "[INFO] After changing SSID/hidden outside the FastACL operator page, run:"
echo "       juliang-fastacl-ssid-preserve save"
echo "[INFO] Check state: juliang-fastacl-ssid-preserve status"
echo "[INFO] Backup: $BK"
