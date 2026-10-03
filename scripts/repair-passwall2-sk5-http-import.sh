#!/bin/sh
set -eu

TARGET="${PW2_SUBSCRIBE:-/usr/share/passwall2/subscribe.lua}"
MODE="${1:-apply}"
MARKER_OLD="JuLiangTK: PassWall2 SK5 HTTP runtime import"
MARKER_NEW="JuLiangTK: PassWall2 SK5 HTTP runtime import v2.4.2"
LINK_MARKER_OLD="JuLiangTK: provider shorthand + sk5 alias"
LINK_MARKER_NEW="JuLiangTK: provider shorthand + sk5 alias v2.4.2"

fail() { echo "[ERROR] $*" >&2; exit 1; }

[ -s "$TARGET" ] || fail "PassWall2 subscribe.lua not found: $TARGET"
command -v lua >/dev/null 2>&1 || fail "lua not found"
lua -e "assert(loadfile('$TARGET'))" || fail "existing subscribe.lua has Lua syntax errors"

# Imported SOCKS/HTTP nodes use sing-box in this FastACL integration. Refuse to
# advertise a working import path when the required runtime is absent.
if ! command -v sing-box >/dev/null 2>&1; then
  fail "sing-box not found; SK5/SOCKS/HTTP imported nodes cannot run"
fi

selftest() {
  lua <<'LUA'
local function pct_encode(v)
  return (v:gsub("([^%w%-._~])", function(c) return string.format("%%%02X", string.byte(c)) end))
end
local function canon(node)
  local base, frag = node:match("^(.-)#(.*)$")
  base = base or node
  local scheme, body = base:match("^([%a][%w+.-]*)://(.+)$")
  local supported = { sk5=true, socks5=true, socks5h=true, socks=true, http=true }
  if scheme then
    scheme = scheme:lower()
    if not supported[scheme] then return node end
  else
    body = base
  end
  local h, p, u, pw = body:match("^([^:%s]+):(%d+):([^:]+):(.+)$")
  if h and p and u and pw then
    local out_scheme = (scheme == nil or scheme == "sk5") and "socks5" or scheme
    local label = frag or (((out_scheme == "http") and "HTTP-" or "SK5-") .. h .. "-" .. p)
    return out_scheme .. "://" .. pct_encode(u) .. ":" .. pct_encode(pw) .. "@" .. h .. ":" .. p .. "#" .. label
  end
  if scheme == "sk5" then
    return "socks5://" .. body .. (frag and ("#" .. frag) or "")
  end
  return node
end
local tests = {
  {"1.2.3.4:1080:user:pass", "socks5://user:pass@1.2.3.4:1080#SK5-1.2.3.4-1080"},
  {"sk5://1.2.3.4:1080:user:pass", "socks5://user:pass@1.2.3.4:1080#SK5-1.2.3.4-1080"},
  {"socks5://1.2.3.4:1080:user:pass", "socks5://user:pass@1.2.3.4:1080#SK5-1.2.3.4-1080"},
  {"http://1.2.3.4:8080:user:pass", "http://user:pass@1.2.3.4:8080#HTTP-1.2.3.4-8080"},
  {"sk5://1.2.3.4:1080:user:p@ss:word#Home", "socks5://user:p%40ss%3Aword@1.2.3.4:1080#Home"},
  {"sk5://user:pass@1.2.3.4:1080#Named", "socks5://user:pass@1.2.3.4:1080#Named"}
}
for _, t in ipairs(tests) do
  local got = canon(t[1])
  assert(got == t[2], t[1] .. " => " .. got .. " expected " .. t[2])
end
print("[OK] SK5/HTTP canonicalizer self-test")
LUA
}

preflight() {
  selftest
  PW2_SUBSCRIBE="$TARGET" lua <<'LUA'
local path = assert(os.getenv("PW2_SUBSCRIBE"))
local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close()
local new_marker = "JuLiangTK: PassWall2 SK5 HTTP runtime import v2.4.2"
local old_marker = "JuLiangTK: PassWall2 SK5 HTTP runtime import"
local new_link = "JuLiangTK: provider shorthand + sk5 alias v2.4.2"
local old_link = "JuLiangTK: provider shorthand + sk5 alias"
local function has(p, init) return s:find(p, init or 1) ~= nil end
local process_ok = s:find(new_marker,1,true) or s:find(old_marker,1,true) or has("%-%-ssr://")
assert(process_ok, "PassWall2 processData anchor --ssr:// not found")
local link_ok = s:find(new_link,1,true) or s:find(old_link,1,true)
if not link_ok then
  local np = s:find("local%s+node%s*=%s*api%.trim%s*%(%s*v%s*%)")
  assert(np, "PassWall2 link parser local node = api.trim(v) anchor not found")
  local dp = s:find("local%s+dat%s*=%s*split%s*%(%s*node%s*,%s*[\"']://[\"']%s*%)", np)
  assert(dp and dp - np < 1200, "PassWall2 link parser local dat = split(node, ://) anchor not found")
end
print("[OK] PassWall2 subscribe.lua compatibility preflight")
LUA
}

case "$MODE" in
  --check|check)
    preflight
    exit 0
    ;;
  --selftest|selftest)
    selftest
    exit 0
    ;;
  apply|--apply|"") ;;
  *) fail "unknown mode: $MODE" ;;
esac

preflight

BACKUP="${TARGET}.bak.v242.$(date +%Y%m%d-%H%M%S)"
cp -af "$TARGET" "$BACKUP"
echo "[INFO] Backup: $BACKUP"

if ! PW2_SUBSCRIBE="$TARGET" lua <<'LUA'
local path = assert(os.getenv("PW2_SUBSCRIBE"), "PW2_SUBSCRIBE missing")
local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close()

local old_process = "JuLiangTK: PassWall2 SK5 HTTP runtime import"
local new_process = "JuLiangTK: PassWall2 SK5 HTTP runtime import v2.4.2"
local old_link = "JuLiangTK: provider shorthand + sk5 alias"
local new_link = "JuLiangTK: provider shorthand + sk5 alias v2.4.2"

if s:find(new_process, 1, true) then
  -- already new
elseif s:find(old_process, 1, true) then
  s = s:gsub("JuLiangTK: PassWall2 SK5 HTTP runtime import[^\n]*", new_process, 1)
else
  local p = assert(s:find("%-%-ssr://"), "PassWall2 processData anchor --ssr:// not found")
  local block = [[-- JuLiangTK: PassWall2 SK5 HTTP runtime import v2.4.2
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

	]]
  s = s:sub(1, p - 1) .. block .. s:sub(p)
end

local marker_pos = s:find(new_link, 1, true) or s:find(old_link, 1, true)
local node_pos
if marker_pos then
  node_pos = marker_pos
else
  node_pos = assert(s:find("local%s+node%s*=%s*api%.trim%s*%(%s*v%s*%)"), "PassWall2 node parser anchor not found")
end
local dat_pos = assert(s:find("local%s+dat%s*=%s*split%s*%(%s*node%s*,%s*[\"']://[\"']%s*%)", node_pos), "PassWall2 dat parser anchor not found")
assert(dat_pos - node_pos < 2500, "PassWall2 node/dat anchors too far apart")

local function line_start(pos)
  while pos > 1 and s:sub(pos - 1, pos - 1) ~= "\n" do pos = pos - 1 end
  return pos
end
local dat_line = line_start(dat_pos)
local indent = s:sub(dat_line, dat_pos - 1)
local replace_from
if marker_pos then replace_from = line_start(marker_pos) else replace_from = dat_line end

local lines = {
  "-- " .. new_link,
  "local function jfa_pct_encode(v)",
  "\treturn (v:gsub(\"([^%w%-._~])\", function(c) return string.format(\"%%%02X\", string.byte(c)) end))",
  "end",
  "local function jfa_canon_proxy_link(v)",
  "\tlocal base, frag = v:match(\"^(.-)#(.*)$\")",
  "\tbase = base or v",
  "\tlocal scheme, body = base:match(\"^([%a][%w+.-]*)://(.+)$\")",
  "\tlocal supported = { sk5=true, socks5=true, socks5h=true, socks=true, http=true }",
  "\tif scheme then",
  "\t\tscheme = scheme:lower()",
  "\t\tif not supported[scheme] then return v end",
  "\telse",
  "\t\tbody = base",
  "\tend",
  "\tlocal h, p, u, pw = body:match(\"^([^:%s]+):(%d+):([^:]+):(.+)$\")",
  "\tif h and p and u and pw then",
  "\t\tlocal out_scheme = (scheme == nil or scheme == \"sk5\") and \"socks5\" or scheme",
  "\t\tlocal label = frag or (((out_scheme == \"http\") and \"HTTP-\" or \"SK5-\") .. h .. \"-\" .. p)",
  "\t\treturn out_scheme .. \"://\" .. jfa_pct_encode(u) .. \":\" .. jfa_pct_encode(pw) .. \"@\" .. h .. \":\" .. p .. \"#\" .. label",
  "\tend",
  "\tif scheme == \"sk5\" then return \"socks5://\" .. body .. (frag and (\"#\" .. frag) or \"\") end",
  "\treturn v",
  "end",
  "node = jfa_canon_proxy_link(node)"
}
for i = 1, #lines do lines[i] = indent .. lines[i] end
local link_block = table.concat(lines, "\n") .. "\n"
s = s:sub(1, replace_from - 1) .. link_block .. s:sub(dat_line)

local o = assert(io.open(path, "wb")); o:write(s); o:close()
print("[OK] patched " .. path)
LUA
then
  echo "[ERROR] patch failed, restoring backup" >&2
  cp -af "$BACKUP" "$TARGET"
  exit 1
fi

if ! lua -e "assert(loadfile('$TARGET'))"; then
  echo "[ERROR] patched Lua syntax invalid, restoring backup" >&2
  cp -af "$BACKUP" "$TARGET"
  exit 1
fi

grep -q "$MARKER_NEW" "$TARGET" || { echo "[ERROR] v2.4.2 process marker missing, restoring backup" >&2; cp -af "$BACKUP" "$TARGET"; exit 1; }
grep -q "$LINK_MARKER_NEW" "$TARGET" || { echo "[ERROR] v2.4.2 shorthand marker missing, restoring backup" >&2; cp -af "$BACKUP" "$TARGET"; exit 1; }

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] PassWall2 SK5/HTTP import v2.4.2 installed"
echo "[OK] Supports standard auth URI + host:port:user:pass + sk5://host:port:user:pass"
echo "[OK] Compatibility preflight completed before mutation"
echo "[INFO] No PassWall2 proxy core restart was performed"
echo "[INFO] Backup: $BACKUP"
