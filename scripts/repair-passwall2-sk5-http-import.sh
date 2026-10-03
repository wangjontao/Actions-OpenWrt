#!/bin/sh
set -eu

TARGET="/usr/share/passwall2/subscribe.lua"
MARKER="JuLiangTK: PassWall2 SK5 HTTP runtime import"

if [ ! -s "$TARGET" ]; then
  echo "[ERROR] PassWall2 subscribe.lua not found: $TARGET" >&2
  exit 1
fi
if ! command -v lua >/dev/null 2>&1; then
  echo "[ERROR] lua not found" >&2
  exit 1
fi
if ! command -v sing-box >/dev/null 2>&1; then
  echo "[WARN] sing-box not found. Import patch can be installed, but SOCKS/HTTP nodes need sing-box runtime."
fi

BACKUP="${TARGET}.bak.$(date +%Y%m%d-%H%M%S)"
cp -af "$TARGET" "$BACKUP"
echo "[INFO] Backup: $BACKUP"

if grep -q "$MARKER" "$TARGET"; then
  echo "[INFO] PassWall2 SK5/HTTP import patch already installed"
  lua -e "assert(loadfile('$TARGET'))"
  exit 0
fi

PW2_SUBSCRIBE="$TARGET" lua <<'LUA'
local path = assert(os.getenv("PW2_SUBSCRIBE"), "PW2_SUBSCRIBE missing")
local f = assert(io.open(path, "rb"))
local s = f:read("*a")
f:close()

local function replace_once(src, old, new)
  local a, b = src:find(old, 1, true)
  if not a then return src, false end
  return src:sub(1, a - 1) .. new .. src:sub(b + 1), true
end

local marker = "JuLiangTK: PassWall2 SK5 HTTP runtime import"
if s:find(marker, 1, true) then
  print("[INFO] already patched")
  os.exit(0)
end

local process_anchor = "\t}\n\t--ssr://"
local process_patch = [[	}

	-- JuLiangTK: PassWall2 SK5 HTTP runtime import
	if szType == 'socks5' or szType == 'socks5h' or szType == 'socks' or szType == 'sk5' or szType == 'http' then
		if not has_singbox then
			log(2, "Skipping SOCKS/HTTP node because sing-box is not installed.")
			return nil
		end
		local scheme = szType
		if scheme == 'sk5' then scheme = 'socks5' end
		local link, fragment = content:match("^(.-)#(.*)$")
		link = link or content
		local parsed = api.parseURL(scheme .. "://" .. link)
		if not parsed or not parsed.hostname or not parsed.port then
			log(2, "Skipping malformed SOCKS/HTTP node: " .. tostring(content))
			return nil
		end
		local function pct_decode(v)
			return (v or ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
		end
		result.type = "sing-box"
		result.protocol = (scheme == "http") and "http" or "socks"
		result.address = parsed.hostname
		result.port = parsed.port
		result.username = pct_decode(parsed.username)
		result.password = pct_decode(parsed.password)
		result.remarks = pct_decode(fragment or (string.upper(result.protocol) .. "-" .. (result.address or "node") .. "-" .. tostring(result.port or "")))
		return result
	end

	--ssr://]]

local ok
s, ok = replace_once(s, process_anchor, process_patch)
if not ok then
  error("PassWall2 processData anchor not found; unsupported subscribe.lua version")
end

local link_anchor = '\t\t\t\t\t\tlocal node = api.trim(v)\n\t\t\t\t\t\tlocal dat = split(node, "://")'
local link_patch = [[						local node = api.trim(v)
						-- JuLiangTK: provider shorthand + sk5 alias
						if node:match("^sk5://") then
							node = "socks5://" .. node:sub(7)
						end
						local h, p, u, pw = node:match("^([^:%s]+):(%d+):([^:]+):(.+)$")
						if h and p and u and pw then
							local function pct_encode(v)
								return (v:gsub("([^%w%-._~])", function(c) return string.format("%%%02X", string.byte(c)) end))
							end
							node = "socks5://" .. pct_encode(u) .. ":" .. pct_encode(pw) .. "@" .. h .. ":" .. p .. "#SK5-" .. h .. "-" .. p
						end
						local dat = split(node, "://")]]

s, ok = replace_once(s, link_anchor, link_patch)
if not ok then
  error("PassWall2 link parser anchor not found; unsupported subscribe.lua version")
end

local out = assert(io.open(path, "wb"))
out:write(s)
out:close()
print("[OK] patched " .. path)
LUA

if ! lua -e "assert(loadfile('$TARGET'))"; then
  echo "[ERROR] patched Lua syntax invalid, restoring backup" >&2
  cp -af "$BACKUP" "$TARGET"
  exit 1
fi

grep -q "$MARKER" "$TARGET" || {
  echo "[ERROR] patch marker missing, restoring backup" >&2
  cp -af "$BACKUP" "$TARGET"
  exit 1
}
grep -q 'provider shorthand + sk5 alias' "$TARGET" || {
  echo "[ERROR] shorthand patch missing, restoring backup" >&2
  cp -af "$BACKUP" "$TARGET"
  exit 1
}

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] PassWall2 SK5/HTTP one-click import support installed"
echo "[OK] Supported: socks5:// socks5h:// socks:// sk5:// http:// host:port:user:pass"
echo "[INFO] No PassWall2 core restart was performed"
echo "[INFO] Backup: $BACKUP"
