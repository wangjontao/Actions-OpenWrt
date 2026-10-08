#!/bin/sh
set -eu

echo "[DEPRECATED] SSID/hidden persistence workaround has been retired."
echo "[INFO] FastACL 2.4.2 now uses a strict wireless READ-ONLY contract."
echo "[INFO] Redirecting to the read-only repair..."

URL="https://cdn.jsdelivr.net/gh/wangjontao/Actions-OpenWrt@998817c43db86dca6c7485e280632cc9984d25b5/scripts/repair-fastacl242-wireless-readonly.sh"
TMP="/tmp/jfa242-wireless-readonly.sh"

if command -v curl >/dev/null 2>&1; then
    curl -4 -fL --connect-timeout 10 --max-time 60 --retry 3 -o "$TMP" "$URL"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$TMP" "$URL"
else
    echo "[ERROR] curl/wget not found" >&2
    exit 1
fi

chmod +x "$TMP"
exec sh "$TMP"
