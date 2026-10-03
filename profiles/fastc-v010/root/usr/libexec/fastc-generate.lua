#!/usr/bin/lua

local jsonc = require "luci.jsonc"

local DB = "/etc/fastc/nodes.json"
local OUT = "/etc/fastc/config.yaml"

local function readall(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function writeall(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function pct_decode(s)
  s = tostring(s or "")
  s = s:gsub("%+", " ")
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function yq(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", ""):gsub("\n", "\\n")
  return '"' .. s .. '"'
end

local function parse_query(q)
  local out = {}
  for kv in tostring(q or ""):gmatch("[^&]+") do
    local k,v = kv:match("^([^=]+)=(.*)$")
    if k then out[pct_decode(k)] = pct_decode(v) else out[pct_decode(kv)] = "" end
  end
  return out
end

local function split_uri(raw)
  raw = trim(raw)
  local base = raw:match("^(.-)#") or raw
  local scheme, rest = base:match("^([%w+.-]+)://(.+)$")
  if not scheme then return nil, "BAD_URI" end
  scheme = scheme:lower()
  local before_q, q = rest:match("^(.-)%?(.*)$")
  if before_q then rest = before_q else q = "" end
  local auth, hostport = rest:match("^(.-)@(.+)$")
  if not hostport then hostport, auth = rest, "" end
  local host, port
  if hostport:sub(1,1) == "[" then
    host, port = hostport:match("^%[([^%]]+)%]:(%d+)$")
  else
    host, port = hostport:match("^([^:]+):(%d+)$")
  end
  if not host or not port then return nil, "BAD_ADDRESS" end
  return {
    scheme = scheme,
    auth = auth or "",
    host = host,
    port = tonumber(port),
    query = parse_query(q)
  }
end

local function add(lines, s) lines[#lines+1] = s end

local function emit_proxy(lines, n)
  local u, err = split_uri(n.raw or "")
  if not u then return false, err end
  local id = tostring(n.id or "")
  if id == "" then return false, "BAD_ID" end

  if u.scheme == "vless" then
    local uuid = pct_decode(u.auth)
    if uuid == "" then return false, "VLESS_UUID_MISSING" end
    add(lines, "  - name: " .. yq(id))
    add(lines, "    type: vless")
    add(lines, "    server: " .. yq(u.host))
    add(lines, "    port: " .. tostring(u.port))
    add(lines, "    uuid: " .. yq(uuid))
    add(lines, "    udp: true")
    if u.query.flow and u.query.flow ~= "" then add(lines, "    flow: " .. yq(u.query.flow)) end
    add(lines, "    network: " .. yq((u.query.type and u.query.type ~= "") and u.query.type or "tcp"))
    if u.query.security == "tls" or u.query.security == "reality" then
      add(lines, "    tls: true")
      if u.query.sni and u.query.sni ~= "" then add(lines, "    servername: " .. yq(u.query.sni)) end
      if u.query.fp and u.query.fp ~= "" then add(lines, "    client-fingerprint: " .. yq(u.query.fp)) end
    end
    if u.query.security == "reality" then
      if not u.query.pbk or u.query.pbk == "" then return false, "REALITY_PUBLIC_KEY_MISSING" end
      add(lines, "    reality-opts:")
      add(lines, "      public-key: " .. yq(u.query.pbk))
      if u.query.sid and u.query.sid ~= "" then add(lines, "      short-id: " .. yq(u.query.sid)) end
    end
    return true
  end

  if u.scheme == "socks5" or u.scheme == "socks5h" or u.scheme == "socks" then
    local user, pass = u.auth:match("^([^:]*):(.*)$")
    add(lines, "  - name: " .. yq(id))
    add(lines, "    type: socks5")
    add(lines, "    server: " .. yq(u.host))
    add(lines, "    port: " .. tostring(u.port))
    add(lines, "    udp: true")
    if user and user ~= "" then add(lines, "    username: " .. yq(pct_decode(user))) end
    if pass and pass ~= "" then add(lines, "    password: " .. yq(pct_decode(pass))) end
    return true
  end

  if u.scheme == "http" then
    local user, pass = u.auth:match("^([^:]*):(.*)$")
    add(lines, "  - name: " .. yq(id))
    add(lines, "    type: http")
    add(lines, "    server: " .. yq(u.host))
    add(lines, "    port: " .. tostring(u.port))
    if user and user ~= "" then add(lines, "    username: " .. yq(pct_decode(user))) end
    if pass and pass ~= "" then add(lines, "    password: " .. yq(pct_decode(pass))) end
    return true
  end

  if u.scheme == "trojan" then
    if u.auth == "" then return false, "TROJAN_PASSWORD_MISSING" end
    add(lines, "  - name: " .. yq(id))
    add(lines, "    type: trojan")
    add(lines, "    server: " .. yq(u.host))
    add(lines, "    port: " .. tostring(u.port))
    add(lines, "    password: " .. yq(pct_decode(u.auth)))
    add(lines, "    udp: true")
    if u.query.security == "tls" or u.query.sni or u.query.fp then
      if u.query.sni and u.query.sni ~= "" then add(lines, "    sni: " .. yq(u.query.sni)) end
      if u.query.fp and u.query.fp ~= "" then add(lines, "    client-fingerprint: " .. yq(u.query.fp)) end
    end
    return true
  end

  return false, "RUNTIME_UNSUPPORTED:" .. u.scheme
end

local nodes = {}
local raw = readall(DB)
if raw and raw ~= "" then
  local ok, obj = pcall(jsonc.parse, raw)
  if ok and type(obj) == "table" then nodes = obj end
end

local lines = {
  "# Generated by FastC 0.1.3-dev. Do not edit by hand.",
  "mode: rule",
  "log-level: warning",
  "allow-lan: false",
  "ipv6: false",
  "external-controller: 127.0.0.1:9097",
  "proxies:"
}

local supported = {}
local rejected = {}
for _,n in ipairs(nodes) do
  local before = #lines
  local ok, err = emit_proxy(lines, n)
  if ok then
    supported[#supported+1] = tostring(n.id)
  else
    while #lines > before do table.remove(lines) end
    rejected[#rejected+1] = {id=n.id, error=err}
  end
end
if #supported == 0 then add(lines, "  []") end

add(lines, "proxy-groups:")
local have_group = false
for i=1,20 do
  local g = "A" .. i
  local members = {}
  for _,n in ipairs(nodes) do
    if n.group == g then
      for _,sid in ipairs(supported) do
        if sid == tostring(n.id) then members[#members+1] = sid break end
      end
    end
  end
  if #members > 0 then
    have_group = true
    add(lines, "  - name: " .. yq("FASTC-" .. g))
    add(lines, "    type: select")
    add(lines, "    proxies:")
    for _,m in ipairs(members) do add(lines, "      - " .. yq(m)) end
  end
end
if not have_group then add(lines, "  []") end

add(lines, "rules:")
add(lines, "  - MATCH,DIRECT")
add(lines, "")

os.execute("mkdir -p /etc/fastc")
writeall(OUT, table.concat(lines, "\n"))
io.write(jsonc.stringify({ok=true,config=OUT,supported=supported,rejected=rejected,total=#nodes}, true), "\n")
