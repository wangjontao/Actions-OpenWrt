#!/bin/sh
set -eu

echo "=================================================="
echo " JuLiang Legacy PassWall SK5/HTTP Import Fix"
echo " PassWall + PassWall2 runtime patch"
echo "=================================================="

command -v lua >/dev/null 2>&1 || {
  echo "[ERROR] lua not found" >&2
  exit 1
}

BK="/etc/juliang-fastacl/legacy-sk5-http-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"

patch_one() {
  APP="$1"
  VIEW="$2"
  SUB="$3"
  XRAY="$4"

  [ -f "$SUB" ] || {
    echo "[SKIP] $APP subscribe.lua not found: $SUB"
    return 0
  }

  mkdir -p "$BK/$APP"
  cp -af "$VIEW" "$BK/$APP/" 2>/dev/null || true
  cp -af "$SUB" "$BK/$APP/" 2>/dev/null || true
  cp -af "$XRAY" "$BK/$APP/" 2>/dev/null || true

  APP="$APP" VIEW="$VIEW" SUB="$SUB" XRAY="$XRAY" lua <<'LUA'
local app  = os.getenv("APP")
local view = os.getenv("VIEW")
local sub  = os.getenv("SUB")
local xray = os.getenv("XRAY")

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

-- Backend: add socks5/socks/http URI parsing and shorthand conversion.
do
  local s = assert(read(sub), "cannot read " .. sub)
  local marker = "JuLiangTK: import SOCKS5/SOCKS/HTTP provider links"

  if not s:find(marker, 1, true) then
    local process_pos = s:find("local function processData", 1, true)
    assert(process_pos, "processData not found in " .. sub)

    local anchor = "\tif szType == 'ssr' then"
    local pos = s:find(anchor, process_pos, true)
    assert(pos, "SSR anchor not found in " .. sub)

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

    local parse_pos = assert(s:find("local function parse_link", 1, true), "parse_link not found")
    local token = "local node = api.trim(v)"
    local node_pos = assert(s:find(token, parse_pos, true), "parse_link node anchor not found")
    local line_start = s:sub(1,node_pos-1):match(".*()\n") or 1
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
    assert(ok, "parse_link exact line not found")
    write(sub, s)
  end
end

-- Frontend: allow multiline shorthand when the legacy page has the known validator.
if view and view ~= "" then
  local s = read(view)
  if s and not s:find("JuLiangTK: allow multiline SOCKS5 shorthand",1,true) then
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
				return p.length >= 4 && p[0].trim() !== "" && /^[0-9]+$/.test(p[1]) &&
					Number(p[1]) >= 1 && Number(p[1]) <= 65535 &&
					p[2].trim() !== "" && p.slice(3).join(":") !== "";
			});
			if (valid) ajax_add_node(nodes_link, group);
			else alert("<%:Please enter the correct link.%>");
		}]]
    local ok
    s, ok = replace_once(s, old, new)
    if ok then
      write(view, s)
    else
      io.stderr:write("[WARN] " .. app .. " frontend validator layout differs; backend import still patched\n")
    end
  end
end

-- Xray SOCKS outbound must not inherit mark=255.
if xray and xray ~= "" then
  local s = read(xray)
  if s and not s:find('mark = (node.protocol ~= "socks") and 255 or nil,',1,true) then
    local p = s:find('streamSettings = (node.streamSettings or node.protocol == "vmess"',1,true)
    if p then
      local m1,m2 = s:find("mark = 255,", p, true)
      if m1 and m1-p < 900 then
        s = s:sub(1,m1-1) .. 'mark = (node.protocol ~= "socks") and 255 or nil,' .. s:sub(m2+1)
        write(xray, s)
      end
    end
  end
end

local verify = assert(read(sub))
assert(verify:find("JuLiangTK: import SOCKS5/SOCKS/HTTP provider links",1,true), "backend marker missing")
assert(verify:find("provider shorthand host:port:username:password",1,true), "shorthand marker missing")
print("[OK] " .. app .. ": SK5/SOCKS5/HTTP direct import backend installed")
LUA
}

patch_one "passwall" \
  "/usr/lib/lua/luci/view/passwall/node_list/link_add_node.htm" \
  "/usr/share/passwall/subscribe.lua" \
  "/usr/lib/lua/luci/passwall/util_xray.lua"

patch_one "passwall2" \
  "/usr/lib/lua/luci/view/passwall2/node_list/link_add_node.htm" \
  "/usr/share/passwall2/subscribe.lua" \
  "/usr/lib/lua/luci/passwall2/util_xray.lua"

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "[OK] Legacy PassWall/PassWall2 SK5 + HTTP import patch finished"
echo "[INFO] Backup: $BK"
echo "[INFO] Supported:"
echo "       socks5://user:pass@host:port"
echo "       socks://user:pass@host:port"
echo "       http://user:pass@host:port"
echo "       host:port:user:pass"
echo "       multiline input"
