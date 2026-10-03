#!/usr/bin/lua

local jsonc = require "luci.jsonc"

local input = arg[1] or "/tmp/fastc-import.links"
local dbpath = arg[2] or "/etc/fastc/nodes.json"

local function readall(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function writeall(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function pct_decode(s)
  s = tostring(s or "")
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function split_fragment(raw)
  local base, frag = raw:match("^(.-)#(.*)$")
  return base or raw, pct_decode(frag or "")
end

local function authority_host_port(base)
  local auth = base:match("^[%w+.-]+://(.+)$") or ""
  auth = auth:match("^([^/?]+)") or auth
  local hostport = auth:match("@(.+)$") or auth
  local host, port
  if hostport:sub(1,1) == "[" then
    host, port = hostport:match("^%[([^%]]+)%]:(%d+)$")
  else
    host, port = hostport:match("^([^:]+):(%d+)$")
  end
  return host or "", tonumber(port or "") or 0
end

local function classify(line)
  local raw = trim(line)
  if raw == "" or raw:sub(1,1) == "#" then return nil end

  if not raw:find("://", 1, true) then
    local h, p, u, pw = raw:match("^([^:]+):(%d+):([^:]+):(.+)$")
    if h and p and u and pw then
      local function enc(v) return (v:gsub("[^%w%-._~]",function(c) return string.format("%%%02X",c:byte()) end)) end
      raw = "socks5://" .. enc(u) .. ":" .. enc(pw) .. "@" .. h .. ":" .. p .. "#SK5-" .. h .. "-" .. p
    else
      return nil, "UNSUPPORTED_FORMAT"
    end
  end

  raw=raw:gsub("^sk5://","socks5://"):gsub("^socks://","socks5://")
  local scheme = (raw:match("^([%w+.-]+)://") or ""):lower()
  -- Accept only protocols the installed generator can run.
  local allowed = {vless=true,trojan=true,socks5=true,socks5h=true,http=true,https=true}
  if not allowed[scheme] then return nil, "UNSUPPORTED_PROTOCOL:" .. scheme end

  local base, remark = split_fragment(raw)
  local host, port = authority_host_port(base)
  if host=="" or port<1 or port>65535 then return nil,"BAD_ADDRESS_OR_PORT" end
  local display_type = scheme
  if scheme == "socks5h" then display_type = "socks5" end
  if scheme == "hy2" then display_type = "hysteria2" end

  return {
    raw = raw,
    type = display_type,
    name = remark,
    address = host,
    port = port
  }
end

local nodes = {}
do
  local old = readall(dbpath)
  if old and old ~= "" then
    local ok, obj = pcall(jsonc.parse, old)
    if ok and type(obj) == "table" then nodes = obj end
  end
end

local seen = {}
local next_num = 1
for _, n in ipairs(nodes) do
  if n.raw then seen[n.raw] = true end
  local x = tonumber(tostring(n.id or ""):match("^n(%d+)$"))
  if x and x >= next_num then next_num = x + 1 end
end

local function alloc_id()
  local id = string.format("n%04d", next_num)
  next_num = next_num + 1
  return id
end

local raw = assert(readall(input), "cannot read import file: " .. input)
local added, duplicate, rejected = 0, 0, {}

for line in raw:gmatch("[^\r\n]+") do
  local item, err = classify(line)
  if item then
    if seen[item.raw] then
      duplicate = duplicate + 1
    else
      item.id = alloc_id()
      if not item.name or item.name == "" then
        local suffix = item.address ~= "" and item.address or item.id
        item.name = string.upper(item.type) .. "-" .. suffix
      end
      item.enabled = true
      item.created_at = os.time()
      nodes[#nodes + 1] = item
      seen[item.raw] = true
      added = added + 1
    end
  elseif err then
    rejected[#rejected + 1] = { line_number = added + duplicate + #rejected + 1, error = err }
  end
end

os.execute("mkdir -p /etc/fastc")
writeall(dbpath..".tmp", jsonc.stringify(nodes, true)); assert(os.rename(dbpath..".tmp",dbpath))

io.write(jsonc.stringify({
  ok = true,
  added = added,
  duplicate = duplicate,
  rejected = rejected,
  total = #nodes
}, true), "\n")
