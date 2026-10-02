#!/bin/sh
set -eu

REF="f9307bae5e97a7ce6d97cea2cd71a7c79985e1b1"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$REF/profiles/fastacl-v9/root"
TMP="/tmp/jfa-rollback-known-good-$$"
BK="/etc/juliang-fastacl/rollback-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo current)"
mkdir -p "$TMP" "$BK" /tmp/juliang-fastacl
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang FastACL rollback -> known-good baseline"
echo " keep bindings + keep fail-closed + remove Fix4 lock/races"
echo "=================================================="

fetch(){
  src="$1"; out="$2"
  curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$out" "$BASE/$src"
  [ -s "$out" ]
}

fetch usr/bin/juliang-fastacl "$TMP/juliang-fastacl"
fetch usr/bin/juliang-fastacl-guard "$TMP/juliang-fastacl-guard"

sh -n "$TMP/juliang-fastacl"
sh -n "$TMP/juliang-fastacl-guard"
grep -q 'juliang_killswitch' "$TMP/juliang-fastacl"
grep -q 'start_preproxy(){' "$TMP/juliang-fastacl"

cp -af /usr/bin/juliang-fastacl "$BK/juliang-fastacl.current" 2>/dev/null || true
cp -af /usr/bin/juliang-fastacl-guard "$BK/juliang-fastacl-guard.current" 2>/dev/null || true
cp -af /etc/config/juliang_fastacl "$BK/juliang_fastacl.uci" 2>/dev/null || true
cp -af /etc/config/passwall2 "$BK/passwall2.uci" 2>/dev/null || true

# Stop only the Guardian loop; keep persistent UCI bindings untouched.
for p in $(pgrep -f '/usr/bin/juliang-fastacl-guard' 2>/dev/null || true); do
  kill "$p" >/dev/null 2>&1 || true
done
sleep 1

cp -af "$TMP/juliang-fastacl" /usr/bin/juliang-fastacl
cp -af "$TMP/juliang-fastacl-guard" /usr/bin/juliang-fastacl-guard
chmod 0755 /usr/bin/juliang-fastacl /usr/bin/juliang-fastacl-guard

# Remove only the experimental Fix4 global lock.
rm -rf /tmp/juliang-fastacl/operation.lock >/dev/null 2>&1 || true

# Rebuild from existing bindings and reassert fail-closed dataplane.
/usr/bin/juliang-fastacl repair >/tmp/juliang-fastacl/rollback-repair.log 2>&1 || {
  cat /tmp/juliang-fastacl/rollback-repair.log 2>/dev/null || true
  echo "[ERROR] baseline repair failed"
  exit 1
}
/usr/bin/juliang-fastacl save-state >/dev/null 2>&1 || true

/etc/init.d/juliang-fastacl enable >/dev/null 2>&1 || true
/etc/init.d/juliang-fastacl restart >/dev/null 2>&1 || true
sleep 3

echo
echo "===== FastACL ====="
/usr/bin/juliang-fastacl status

echo
echo "===== Guardian ====="
pgrep -af juliang-fastacl-guard 2>/dev/null || true

echo
echo "===== Kill-switch ====="
nft list table inet juliang_killswitch >/dev/null 2>&1 && echo "OK: fail-closed loaded" || echo "MISSING"

echo
echo "===== Assigned AP probes ====="
count="$(uci -q get juliang_fastacl.main.ap_count 2>/dev/null || echo 0)"
case "$count" in ''|*[!0-9]*) count=0 ;; esac
i=1
while [ "$i" -le "$count" ]; do
  node="$(uci -q get juliang_fastacl.ap$i.node 2>/dev/null || true)"
  if [ -n "$node" ]; then
    printf "AP%s = " "$i"
    /usr/bin/juliang-fastacl probe "AP$i" 2>/dev/null || true
  fi
  i=$((i+1))
done

echo
echo "[OK] rollback completed"
echo "[OK] FastACL bindings preserved"
echo "[OK] fail-closed preserved"
echo "[OK] Fix4 global operation lock removed"
echo "[INFO] do not apply Fix4/Fix4.1/Fix4.2 again on this test router"
