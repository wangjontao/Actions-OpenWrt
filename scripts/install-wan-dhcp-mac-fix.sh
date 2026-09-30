#!/usr/bin/env bash
set -euo pipefail

ROOTFS="$1"
mkdir -p "$ROOTFS/usr/sbin" "$ROOTFS/etc/init.d" "$ROOTFS/etc/uci-defaults"

cat > "$ROOTFS/usr/sbin/wan-dhcp-heal" <<'WANHEAL'
#!/bin/sh

TAG='wan-dhcp-heal'
LOCK='/var/run/wan-dhcp-heal.lock'
MAC_FILE='/etc/wan-dhcp-heal.mac'
LAST_AGGR='/tmp/wan-dhcp-heal.last_aggressive'

log_msg() {
    logger -t "$TAG" "$*"
}

wan_proto() {
    uci -q get network.wan.proto
}

wan_status() {
    ubus call network.interface.wan status 2>/dev/null
}

wan_ip() {
    wan_status | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null
}

wan_dev() {
    local dev st

    dev="$(uci -q get network.wan.device)"
    [ -n "$dev" ] || dev="$(uci -q get network.wan.ifname)"

    if [ -z "$dev" ]; then
        st="$(wan_status)"
        dev="$(printf '%s' "$st" | jsonfilter -e '@.device' 2>/dev/null)"
        [ -n "$dev" ] || dev="$(printf '%s' "$st" | jsonfilter -e '@.l3_device' 2>/dev/null)"
    fi

    printf '%s\n' "$dev"
}

valid_mac() {
    printf '%s\n' "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
}

save_initial_mac() {
    local dev mac

    [ -s "$MAC_FILE" ] && return 0

    dev="$(wan_dev)"
    [ -n "$dev" ] || return 0
    [ -r "/sys/class/net/$dev/address" ] || return 0

    mac="$(cat "/sys/class/net/$dev/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    valid_mac "$mac" || return 0
    [ "$mac" = '00:00:00:00:00:00' ] && return 0

    printf '%s\n' "$mac" > "$MAC_FILE"
    chmod 600 "$MAC_FILE"
    log_msg "Pinned initial WAN MAC $mac on $dev"
}

apply_saved_mac() {
    local dev saved current

    dev="$1"
    [ -n "$dev" ] || return 0
    [ -s "$MAC_FILE" ] || return 0
    [ -r "/sys/class/net/$dev/address" ] || return 0

    saved="$(head -n1 "$MAC_FILE" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    valid_mac "$saved" || return 0

    current="$(cat "/sys/class/net/$dev/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [ "$current" = "$saved" ] && return 0

    log_msg "Restoring WAN MAC $current -> $saved on $dev"
    ip link set dev "$dev" down >/dev/null 2>&1 || return 0
    ip link set dev "$dev" address "$saved" >/dev/null 2>&1 || true
    ip link set dev "$dev" up >/dev/null 2>&1 || true
}

carrier_up() {
    local dev carrier

    dev="$1"
    [ -n "$dev" ] || return 0
    [ -r "/sys/class/net/$dev/carrier" ] || return 0
    carrier="$(cat "/sys/class/net/$dev/carrier" 2>/dev/null)"
    [ "$carrier" != '0' ]
}

check_once() {
    local ip dev now last

    [ "$(wan_proto)" = 'dhcp' ] || return 0

    mkdir "$LOCK" 2>/dev/null || return 0
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM

    save_initial_mac
    dev="$(wan_dev)"
    apply_saved_mac "$dev"

    ip="$(wan_ip)"
    [ -n "$ip" ] && return 0

    if ! carrier_up "$dev"; then
        log_msg "WAN has no IPv4 and physical carrier is down on $dev; waiting"
        return 0
    fi

    log_msg 'WAN has no IPv4; requesting DHCP renew'
    ubus call network.interface.wan renew >/dev/null 2>&1 || true
    sleep 8

    ip="$(wan_ip)"
    if [ -n "$ip" ]; then
        log_msg "DHCP renew recovered WAN: $ip"
        return 0
    fi

    now="$(date +%s)"
    last="$(cat "$LAST_AGGR" 2>/dev/null || echo 0)"
    case "$last" in
        ''|*[!0-9]*) last=0 ;;
    esac

    if [ $((now - last)) -lt 180 ]; then
        log_msg 'WAN still has no IPv4; aggressive recovery is in 180-second cooldown'
        return 0
    fi

    printf '%s\n' "$now" > "$LAST_AGGR"

    log_msg 'DHCP renew failed; restarting WAN only'
    ifdown wan >/dev/null 2>&1 || true
    sleep 3
    apply_saved_mac "$dev"
    ifup wan >/dev/null 2>&1 || true
    sleep 15

    ip="$(wan_ip)"
    if [ -n "$ip" ]; then
        log_msg "WAN restart recovered DHCP: $ip"
        return 0
    fi

    log_msg 'WAN restart failed; resetting WAN physical link and retrying'
    if [ -n "$dev" ] && ip link show "$dev" >/dev/null 2>&1; then
        ip link set dev "$dev" down >/dev/null 2>&1 || true
        sleep 4
        apply_saved_mac "$dev"
        ip link set dev "$dev" up >/dev/null 2>&1 || true
        sleep 4
    fi

    ifup wan >/dev/null 2>&1 || true
    sleep 15

    ip="$(wan_ip)"
    if [ -n "$ip" ]; then
        log_msg "WAN link reset recovered DHCP: $ip"
    else
        log_msg 'Recovery exhausted; upstream DHCP server/optical modem may be holding a stale lease'
    fi
}

case "$1" in
    daemon)
        sleep 60
        while :; do
            "$0" check
            sleep 60
        done
        ;;
    check|'')
        check_once
        ;;
esac
WANHEAL
chmod 0755 "$ROOTFS/usr/sbin/wan-dhcp-heal"

cat > "$ROOTFS/etc/init.d/wan-dhcp-heal" <<'WANINIT'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=96
STOP=10

start_service() {
    [ "$(uci -q get network.wan.proto)" = 'dhcp' ] || return 0

    procd_open_instance
    procd_set_param command /usr/sbin/wan-dhcp-heal daemon
    procd_set_param respawn 3600 5 5
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger network
}
WANINIT
chmod 0755 "$ROOTFS/etc/init.d/wan-dhcp-heal"

cat > "$ROOTFS/etc/uci-defaults/96-wan-dhcp-mac-lease-fix" <<'WANDEFAULT'
#!/bin/sh

if [ "$(uci -q get network.wan.proto)" = 'dhcp' ]; then
    uci -q set network.wan.broadcast='1'
    uci -q commit network
fi

/etc/init.d/wan-dhcp-heal enable
/etc/init.d/wan-dhcp-heal start >/dev/null 2>&1 || true
exit 0
WANDEFAULT
chmod 0755 "$ROOTFS/etc/uci-defaults/96-wan-dhcp-mac-lease-fix"

echo "Installed WAN DHCP/MAC lease self-healing into $ROOTFS"
