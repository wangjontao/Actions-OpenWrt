#!/bin/sh
set -eu

REPO="wangjontao/Actions-OpenWrt"
INSTALLER_REF="a563f709171b55690e8c93f906f87bbcd366a0e4"
SRC="/tmp/fastc-install-018-main.sh"
PATCHED="/tmp/fastc-install-018-api-main.sh"
API="https://api.github.com/repos/$REPO/contents"

fetch_raw(){
  url="$1"
  out="$2"
  curl -4 --http1.1 -fL \
    --connect-timeout 15 --max-time 180 --retry 5 --retry-delay 2 \
    -H 'Accept: application/vnd.github.raw+json' \
    -H 'User-Agent: FastC-Installer' \
    -o "$out" "$url"
}

echo "=================================================="
echo " FastC 0.1.8 GitHub-API bootstrap"
echo " No jsDelivr required"
echo "=================================================="

rm -f "$SRC" "$PATCHED"
fetch_raw "$API/scripts/fastc-install.sh?ref=$INSTALLER_REF" "$SRC"
[ -s "$SRC" ] || { echo "[ERROR] installer download is empty" >&2; exit 1; }

# Replace the original single-CDN downloader with GitHub official Contents API raw.
awk '
/^BASE=/ { print "BASE_API=\"https://api.github.com/repos/wangjontao/Actions-OpenWrt/contents/profiles/fastc-v010/root\""; next }
/^get\(\)\{/ {
  print "get(){"
  print "  rel=\"$1\"; out=\"$2\""
  print "  mkdir -p \"$(dirname \"$out\")\""
  print "  echo \"[INFO] GitHub API: $rel\""
  print "  curl -4 --http1.1 -fL --connect-timeout 15 --max-time 180 --retry 5 --retry-delay 2 -H \"Accept: application/vnd.github.raw+json\" -H \"User-Agent: FastC-Installer\" -o \"$out\" \"$BASE_API/$rel?ref=$PIN\""
  print "}"
  next
}
{ print }
' "$SRC" > "$PATCHED"

chmod +x "$PATCHED"
echo "[OK] GitHub API installer prepared"
exec sh "$PATCHED"
