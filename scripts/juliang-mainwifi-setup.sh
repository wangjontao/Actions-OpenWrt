#!/bin/sh
set -eu
MARKER=/etc/juliang-fastacl243-mainwifi.done
[ -e "$MARKER" ] && exit 0
mkdir /tmp/juliang-mainwifi-setup.lock 2>/dev/null || exit 0
trap 'rmdir /tmp/juliang-mainwifi-setup.lock' EXIT
radio2=''; radio5=''; tries=0
while [ -z "$radio2" ] || [ -z "$radio5" ]; do
  for dev in $(uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-device$/\1/p'); do
    band=$(uci -q get wireless.$dev.band || true)
    hw=$(uci -q get wireless.$dev.hwmode || true)
    case "$band:$hw" in 2g:*|*:11g) radio2=$dev;;5g:*|*:11a) radio5=$dev;;esac
  done
  tries=$((tries+1)); [ "$tries" -lt 60 ] || exit 1
  [ -n "$radio2" ] && [ -n "$radio5" ] || sleep 2
done
# Preserve user-created batch wireless on a configuration-preserving upgrade.
if uci -q show wireless | grep -q "jfa_owner='fastacl-batch-v1'"; then touch "$MARKER"; exit 0; fi
for iface in $(uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do uci -q delete wireless.$iface; done
for spec in "$radio2:2:JuLiangTk-2.4G:9" "$radio5:5:JuLiangTk-5G:48"; do
  dev=${spec%%:*}; rest=${spec#*:}; idx=${rest%%:*}; rest=${rest#*:}; ssid=${rest%%:*}; channel=${rest##*:}
  uci set wireless.$dev.channel="$channel"
  uci set wireless.$dev.disabled='0'
  iface=juliang_main$idx
  uci set wireless.$iface='wifi-iface'
  uci set wireless.$iface.device="$dev"
  uci set wireless.$iface.mode='ap'
  uci set wireless.$iface.network='lan'
  uci set wireless.$iface.ssid="$ssid"
  uci set wireless.$iface.encryption='psk2+ccmp'
  uci set wireless.$iface.key='a1111111'
  uci set wireless.$iface.hidden='0'
  uci set wireless.$iface.disabled='0'
done
uci commit wireless
uci set juliang_fastacl.main.include_lan='1'
uci set juliang_fastacl.main.version='2.4.3'
uci commit juliang_fastacl
/etc/init.d/network reload >/dev/null 2>&1 || true
wifi reload >/dev/null 2>&1 || true
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
/etc/init.d/passwall stop >/dev/null 2>&1 || true
/etc/init.d/passwall disable >/dev/null 2>&1 || true
/etc/init.d/passwall2 stop >/dev/null 2>&1 || true
/etc/init.d/passwall2 disable >/dev/null 2>&1 || true
/usr/bin/juliang-fastacl discover >/tmp/juliang-mainwifi-discover.log 2>&1
if [ "$(uci -q get juliang_fastacl.main.runtime_mode)" = normal_proxy ]; then
  /usr/bin/juliang-fastacl-runtime set normal_proxy
else
  /etc/init.d/juliang-fastacl enable
  /etc/init.d/juliang-fastacl restart
  /usr/bin/juliang-fastacl ensure
  /usr/bin/juliang-fastacl-mode apply
fi
touch "$MARKER"
logger -t juliang-mainwifi 'FastACL2.4.3: main WiFi only; JuLiangTk-5G channel48 / JuLiangTk-2.4G channel9'
