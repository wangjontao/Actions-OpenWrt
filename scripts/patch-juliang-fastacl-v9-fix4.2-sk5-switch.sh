#!/bin/sh
set -eu

PIN="1edc7d09a97df67d46ec8078571514caacb86d23"
URL="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root/usr/bin/juliang-fastacl"
TMP="/tmp/jfa-fix42-engine-$$"

echo "=================================================="
echo " JuLiang FastACL V9 Fix4.2"
echo " SK5 rapid-switch stale relay/IP fix"
echo "=================================================="

curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$TMP" "$URL"
sh -n "$TMP"
grep -q 'STALE_LISTENER' "$TMP"
grep -q 'rm -f "$RUN_DIR/ap$n.ip"' "$TMP"
grep -q 'echo "$$" > "$OP_LOCK/pid"' "$TMP"

mkdir -p /etc/juliang-fastacl
cp -af /usr/bin/juliang-fastacl /etc/juliang-fastacl/juliang-fastacl.pre-fix42 2>/dev/null || true
cp -af "$TMP" /usr/bin/juliang-fastacl
chmod 0755 /usr/bin/juliang-fastacl
rm -f "$TMP"
rm -rf /tmp/juliang-fastacl/operation.lock >/dev/null 2>&1 || true

echo "===== FastACL ====="
/usr/bin/juliang-fastacl status
echo
echo "[OK] Fix4.2 installed"
echo "[OK] old 131xx/141xx relay is fully stopped before a new SK5 starts"
echo "[OK] stale displayed AP IP is cleared at switch start"
echo "[OK] switch refuses success if the old 131xx listener is still present"
