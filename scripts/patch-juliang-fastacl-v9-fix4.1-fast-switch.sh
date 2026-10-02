#!/bin/sh
set -eu

PIN="00f159ecb76cdea344ac512bb786f64b00603c8f"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
TMP="/tmp/jfa-fix41-$$"
mkdir -p "$TMP" /tmp/juliang-fastacl
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang FastACL V9 Fix4.1"
echo " fast switch + nonblocking Guardian"
echo "=================================================="

curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2   -o "$TMP/juliang-fastacl" "$BASE/usr/bin/juliang-fastacl"
curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2   -o "$TMP/juliang-fastacl-guard" "$BASE/usr/bin/juliang-fastacl-guard"

sh -n "$TMP/juliang-fastacl"
sh -n "$TMP/juliang-fastacl-guard"

grep -q 'echo "$$" > "$OP_LOCK/pid"' "$TMP/juliang-fastacl"
grep -q 'JFA_LOCK_TRIES=1' "$TMP/juliang-fastacl-guard"
grep -q 'probe_socks_wait "$port" 2 1' "$TMP/juliang-fastacl"

cp -af /usr/bin/juliang-fastacl /etc/juliang-fastacl/juliang-fastacl.pre-fix41 2>/dev/null || true
cp -af /usr/bin/juliang-fastacl-guard /etc/juliang-fastacl/juliang-fastacl-guard.pre-fix41 2>/dev/null || true

cp -af "$TMP/juliang-fastacl" /usr/bin/juliang-fastacl
cp -af "$TMP/juliang-fastacl-guard" /usr/bin/juliang-fastacl-guard
chmod 0755 /usr/bin/juliang-fastacl /usr/bin/juliang-fastacl-guard

rm -rf /tmp/juliang-fastacl/operation.lock >/dev/null 2>&1 || true

# Reload only Guardian. Leave current AP relays/TProxy untouched.
for p in $(pgrep -f '^/bin/sh /usr/bin/juliang-fastacl-guard$' 2>/dev/null || true); do
  kill "$p" >/dev/null 2>&1 || true
done
sleep 6

echo "===== Guardian ====="
pgrep -af juliang-fastacl-guard 2>/dev/null || echo "[WARN] procd is still respawning Guardian"

echo "===== FastACL ====="
/usr/bin/juliang-fastacl status

echo "[OK] Fix4.1 installed"
echo "[OK] healthy switches use shorter real-egress checks"
echo "[OK] Guardian maintenance will not wait/block a manual switch"
echo "[OK] fail-closed and rollback remain enabled"
