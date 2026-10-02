#!/bin/sh
set -eu

echo "=================================================="
echo " JuLiang PassWall2 SK5/HTTP Runtime Import Fix"
echo " Existing OpenWrt system / PassWall2 only"
echo "=================================================="

command -v lua >/dev/null 2>&1 || {
  echo "[ERROR] lua not found" >&2
  exit 1
}

VIEW="/usr/lib/lua/luci/view/passwall2/node_list/link_add_node.htm"
SUB="/usr/share/passwall2/subscribe.lua"
XRAY="/usr/lib/lua/luci/passwall2/util_xray.lua"

[ -f "$SUB" ] || {
  echo "[ERROR] PassWall2 subscribe.lua not found: $SUB" >&2
  exit 1
}

BK="/etc/passwall2-sk5-http-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"

cp -af "$VIEW" "$BK/" 2>/dev/null || true
cp -af "$SUB" "$BK/" 2>/dev/null || true
cp -af "$XRAY" "$BK/" 2>/dev/null || true

VIEW="$VIEW" SUB="$SUB" XRAY="$XRAY" lua <<'LUA'
local view = os.getenv("VIEW")
local sub  = os.getenv("SUB")
local xray = os.getenv("XRAY")

local FRONT_MARKER = "JuLiangTK: allow multiline SOCKS5 shorthand"
local BACK_MARKER  = "JuLiangTK: import SOCKS5/SOCKS/HTTP provider links"
local XRAY_MARKER  = 'mark = (node.protocol ~= "socks") and 255 or nil,'

local function read(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write(p, s)
  local f = assert(io.open(p, "wb"))
  f:write(s)
  f:close()
end

local function replace_once(s, old, new)
  local a,b = s:find(old, 1, true)
  if not a then return s, false end
  return s:sub(1,a-1) .. new .. s:sub(b+1), true
end

-- Backend: socks5/socks/http URI + host:port:user:pass shorthand.
do
  local s = assert(read(sub), "cannot read " .. sub)

  if not s:find(BACK_MARKER, 1, true) then
    local process_pos = assert(s:find("local function processData", 1, true),
      "processData not found in " .. sub)

    local anchor = "\tif szType == 'ssr' then"
    local pos = assert(s:find(anchor, process_pos, true),
      "SSR anchor not found in " .. sub)

    local branch = [[	-- JuLiangTK: import SOCKS5/SOCKS/HTTP provider links as normal nodes.
	if szType == 'socks5' or szType == 'socks5h' or szType == 'socks' or szType == 'http' then
		if not has_xray and not has_singbox then
			return nil
		end
		local link, fragment = content:match("^(.-)#(.*)$")
		link = link or content
		local parsed = api.parseURL(szType .. "://" .. link)
		if not parsed or not parsed.hostname or not parsed.port then
			return nil
		end
		local function pct_decode(v)
			return (v or ""):gsub("%%(%x%x)", function(h)
				return string.char(tonumber(h, 16))
			end)
		end
		result.type = has_singbox and "sing-box" or "Xray"
		result.protocol = (szType == "http") and "http" or "socks"
		result.transport = "tcp"
		result.stream_security = "none"
		result.address = parsed.hostname
		result.port = parsed.port
		result.username = pct_decode(parsed.username)
		result.password = pct_decode(parsed.password)
		result.remarks = pct_decode(fragment or (string.upper(result.protocol) .. "-" .. result.address .. "-" .. tostring(result.port)))
		return result
	elseif szType == 'ssr' then]]

    s = s:sub(1,pos-1) .. branch .. s:sub(pos + #anchor)

    local parse_pos = assert(s:find("local function parse_link", 1, true),
      "parse_link not found in " .. sub)
    local token = "local node = api.trim(v)"
    local node_pos = assert(s:find(token, parse_pos, true),
      "parse_link node anchor not found in " .. sub)

    local before = s:sub(1, node_pos - 1)
    local line_start = before:match(".*()\n") or 0
    local indent = s:sub(line_start + 1, node_pos - 1)
    local oldline = indent .. token
    local newline = oldline .. "\n"
      .. indent .. "-- JuLiangTK: provider shorthand host:port:username:password -> socks5://\n"
      .. indent .. 'local h, p, u, pw = node:match("^([^:]+):(%d+):([^:]+):(.+)$")\n'
      .. indent .. "if h and p and u and pw then\n"
      .. indent .. '\tnode = "socks5://" .. u .. ":" .. pw .. "@" .. h .. ":" .. p .. "#SK5-" .. h .. "-" .. p\n'
      .. indent .. "end"

    local ok
    s, ok = replace_once(s, oldline, newline)
    assert(ok, "parse_link exact line not found in " .. sub)

    write(sub, s)
  end
end

-- Frontend validator: allow multiline shorthand.
do
  local s = read(view)
  if s and not s:find(FRONT_MARKER, 1, true) then
    local old = [[		if (nodes_link != "") {
			let s = nodes_link.split('://');
			if (s.length > 1) {
				ajax_add_node(nodes_link, group);
			}
			else {
				alert("<%:Please enter the correct link.%>");
			}
		}]]

    local new = [[		if (nodes_link != "") {
			// JuLiangTK: allow multiline SOCKS5 shorthand
			const lines = nodes_link.split("\n").map(function(v) { return v.trim(); }).filter(Boolean);
			const valid = lines.length > 0 && lines.every(function(v) {
				if (v.indexOf("://") !== -1) return true;
				const p = v.split(":");
				return p.length >= 4 && p[0].trim() !== "" &&
					/^[0-9]+$/.test(p[1]) &&
					Number(p[1]) >= 1 && Number(p[1]) <= 65535 &&
					p[2].trim() !== "" && p.slice(3).join(":") !== "";
			});
			if (valid) {
				ajax_add_node(nodes_link, group);
			}
			else {
				alert("<%:Please enter the correct link.%>");
			}
		}]]

    local ok
    s, ok = replace_once(s, old, new)
    if ok then
      write(view, s)
    else
      io.stderr:write("[WARN] PassWall2 frontend validator layout differs; backend import has still been patched\n")
    end
  end
end

-- Xray SOCKS outbound: don't inherit mark=255.
do
  local s = read(xray)
  if s and not s:find(XRAY_MARKER, 1, true) then
    local p = s:find('streamSettings = (node.streamSettings or node.protocol == "vmess"', 1, true)
    if p then
      local m1,m2 = s:find("mark = 255,", p, true)
      if m1 and m1 - p < 900 then
        s = s:sub(1,m1-1) .. XRAY_MARKER .. s:sub(m2+1)
        write(xray, s)
      end
    end
  end
end

local verify = assert(read(sub))
assert(verify:find(BACK_MARKER,1,true), "backend marker missing")
assert(verify:find("provider shorthand host:port:username:password",1,true),
  "shorthand marker missing")

print("[OK] PassWall2 backend: SK5/SOCKS5/HTTP direct import installed")

local v = read(view)
if v and v:find(FRONT_MARKER,1,true) then
  print("[OK] PassWall2 frontend: multiline shorthand validation installed")
else
  print("[WARN] PassWall2 frontend marker not found; backend import is still available")
end

local x = read(xray)
if x and x:find(XRAY_MARKER,1,true) then
  print("[OK] PassWall2 Xray: SOCKS mark fix installed")
else
  print("[WARN] PassWall2 Xray mark anchor not patched; current version may use a different layout")
end
LUA

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "[OK] PassWall2 SK5 + HTTP runtime patch finished"
echo "[INFO] Backup: $BK"
echo "[INFO] Supported:"
echo "       socks5://user:pass@host:port"
echo "       socks://user:pass@host:port"
echo "       http://user:pass@host:port"
echo "       host:port:user:pass"
echo "       multiline input"
