#!/bin/sh
set -eu

PIN="3c377860a0039414b6b6846175ebee3391c2b734"
URL="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root/usr/bin/juliang-fastacl-guard"
TMP="/tmp/jfa-mainlan-privacy-$$"
BK="/etc/juliang-fastacl/mainlan-privacy-backup"

echo "=================================================="
echo " JuLiang FastACL 2.3.3 Main LAN Privacy Fix"
echo " IPv6/DNS leak + video fallback repair"
echo "=================================================="

mkdir -p "$BK" /tmp/juliang-fastacl

# Require main LAN to be part of the current FastACL topology.
has_lan=0
for sec in $(uci -q show juliang_fastacl | sed -n "s/^juliang_fastacl\.\([^.=]*\)=ap$/\1/p"); do
  [ "$(uci -q get juliang_fastacl.$sec.network 2>/dev/null || true)" = "lan" ] && { has_lan=1; break; }
done
[ "$has_lan" -eq 1 ] || {
  echo "[ERROR] main LAN is not in FastACL topology yet"
  exit 1
}

# One-time backup of current network/DHCP/firewall files.
[ -f "$BK/network" ] || cp -af /etc/config/network "$BK/network"
[ -f "$BK/dhcp" ] || cp -af /etc/config/dhcp "$BK/dhcp"
[ -f "$BK/firewall" ] || cp -af /etc/config/firewall "$BK/firewall"

curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$TMP" "$URL"
sh -n "$TMP"
grep -q 'enforce_mainlan_ipv6_privacy' "$TMP"
grep -q 'FastACL block main LAN IPv6 DNS' "$TMP"

cp -af /usr/bin/juliang-fastacl-guard "$BK/juliang-fastacl-guard.pre-233" 2>/dev/null || true
cp -af "$TMP" /usr/bin/juliang-fastacl-guard
chmod 0755 /usr/bin/juliang-fastacl-guard
rm -f "$TMP"

# Find the firewall zone containing network "lan".
zone_sec=""
zone_name=""
for z in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=zone$/\1/p"); do
  name="$(uci -q get firewall.$z.name 2>/dev/null || true)"
  nets="$(uci -q get firewall.$z.network 2>/dev/null || true)"
  if [ "$name" = "lan" ]; then
    zone_sec="$z"; zone_name="$name"; break
  fi
  for n in $nets; do
    if [ "$n" = "lan" ]; then
      zone_sec="$z"; zone_name="$name"; break 2
    fi
  done
done

[ -n "$zone_sec" ] || {
  echo "[ERROR] firewall zone for network lan not found"
  exit 1
}

echo "[INFO] LAN firewall zone: $zone_name ($zone_sec)"

# FastACL dataplane is IPv4. Stop IPv6 advertisement/assignment on the managed
# main LAN so clients cannot bypass proxy DNS or get stuck on half-working IPv6.
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ndp='disabled'
uci set network.lan.ip6assign='0'

# Remove the direct LAN->WAN forwarding. IPv4 FastACL traffic is TProxied before
# forward; IPv6/unproxied traffic is therefore fail-closed instead of leaking.
for sec in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=forwarding$/\1/p"); do
  src="$(uci -q get firewall.$sec.src 2>/dev/null || true)"
  dest="$(uci -q get firewall.$sec.dest 2>/dev/null || true)"
  [ "$src" = "$zone_name" ] && [ "$dest" = "wan" ] && {
    echo "[INFO] remove direct forwarding: $src -> wan ($sec)"
    uci -q delete firewall.$sec
  }
done
uci set firewall.$zone_sec.forward='REJECT'

# Reject IPv6 DNS sent to the router itself while stale client IPv6 state still
# exists. Clients immediately fall back to the IPv4 DNS path intercepted by JFA.
uci -q delete firewall.jfa_mainlan_ipv6_dns >/dev/null 2>&1 || true
uci set firewall.jfa_mainlan_ipv6_dns='rule'
uci set firewall.jfa_mainlan_ipv6_dns.name='FastACL block main LAN IPv6 DNS'
uci set firewall.jfa_mainlan_ipv6_dns.src="$zone_name"
uci set firewall.jfa_mainlan_ipv6_dns.family='ipv6'
uci set firewall.jfa_mainlan_ipv6_dns.proto='tcp udp'
uci set firewall.jfa_mainlan_ipv6_dns.dest_port='53'
uci set firewall.jfa_mainlan_ipv6_dns.target='REJECT'

uci commit dhcp
uci commit network
uci commit firewall
/etc/init.d/odhcpd restart >/dev/null 2>&1 || true
/etc/init.d/firewall restart >/dev/null 2>&1 || true

# Reload only Guardian; do not restart FastACL relays or the current node.
for p in $(pgrep -f '^/bin/sh /usr/bin/juliang-fastacl-guard$' 2>/dev/null || true); do
  kill "$p" >/dev/null 2>&1 || true
done
sleep 6

echo
echo "===== Main LAN privacy ====="
echo "RA:      $(uci -q get dhcp.lan.ra 2>/dev/null || echo -)"
echo "DHCPv6:  $(uci -q get dhcp.lan.dhcpv6 2>/dev/null || echo -)"
echo "NDP:     $(uci -q get dhcp.lan.ndp 2>/dev/null || echo -)"
echo "ip6assign: $(uci -q get network.lan.ip6assign 2>/dev/null || echo -)"

echo
echo "===== LAN -> WAN forwarding ====="
found=0
for sec in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=forwarding$/\1/p"); do
  src="$(uci -q get firewall.$sec.src 2>/dev/null || true)"
  dest="$(uci -q get firewall.$sec.dest 2>/dev/null || true)"
  if [ "$src" = "$zone_name" ] && [ "$dest" = "wan" ]; then
    echo "UNSAFE: $src -> wan ($sec)"
    found=1
  fi
done
[ "$found" -eq 0 ] && echo "OK: no direct main-LAN -> WAN forwarding"

echo
echo "===== FastACL ====="
/usr/bin/juliang-fastacl status

echo
echo "[OK] 2.3.3 main-LAN privacy fix installed"
echo "[INFO] reconnect the main WiFi once so the phone/PC drops its old IPv6 address immediately"
echo "[INFO] then test DNS leak and video playback again"
