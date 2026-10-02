local jsonc = require "luci.jsonc"
local sys = require "luci.sys"
local uci = require("luci.model.uci").cursor()

local function split_words(v)
  local out = {}
  if type(v) == "table" then
    for _, x in ipairs(v) do
      if x and x ~= "" then out[#out + 1] = x end
    end
  elseif type(v) == "string" then
    for x in v:gmatch("%S+") do out[#out + 1] = x end
  end
  return out
end

local function ip_to_num(ip)
  local a,b,c,d = tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  a,b,c,d = tonumber(a),tonumber(b),tonumber(c),tonumber(d)
  if not a or a>255 or b>255 or c>255 or d>255 then return nil end
  return ((a*256+b)*256+c)*256+d
end

local function num_to_ip(n)
  local a = math.floor(n / 16777216) % 256
  local b = math.floor(n / 65536) % 256
  local c = math.floor(n / 256) % 256
  local d = n % 256
  return string.format("%d.%d.%d.%d", a,b,c,d)
end

local function mask_to_prefix(mask)
  if not mask or mask == "" then return 24 end
  local p = tonumber(mask)
  if p and p >= 0 and p <= 32 then return p end
  local n = ip_to_num(mask)
  if not n then return nil end
  local bits = 0
  local seen_zero = false
  for i = 31, 0, -1 do
    local bit = math.floor(n / (2^i)) % 2
    if bit == 1 then
      if seen_zero then return nil end
      bits = bits + 1
    else
      seen_zero = true
    end
  end
  return bits
end

local function cidr_from(ip, mask)
  if not ip or ip == "" then return nil end
  local bare, slash = tostring(ip):match("^([^/]+)/(%d+)$")
  if bare then
    ip = bare
    mask = slash
  end
  local n = ip_to_num(ip)
  local p = mask_to_prefix(mask)
  if not n or not p then return nil end
  local block = 2^(32-p)
  local net = math.floor(n / block) * block
  return num_to_ip(net) .. "/" .. tostring(p)
end

local function network_ipv4(net)
  local ip = uci:get("network", net, "ipaddr")
  local mask = uci:get("network", net, "netmask")
  if type(ip) == "table" then ip = ip[1] end
  local cidr = cidr_from(ip, mask)
  if cidr then return cidr, tostring(ip):match("^([^/]+)") end

  local raw = sys.exec("ubus call network.interface." .. string.format("%q", net) .. " status 2>/dev/null")
  if raw and raw ~= "" then
    local ok, st = pcall(jsonc.parse, raw)
    if ok and type(st) == "table" and type(st["ipv4-address"]) == "table" then
      local a = st["ipv4-address"][1]
      if a and a.address and a.mask then
        return cidr_from(a.address, a.mask), a.address
      end
    end
  end
  return nil
end

local lan_cidr = nil
do
  local ip = uci:get("network", "lan", "ipaddr")
  local mask = uci:get("network", "lan", "netmask")
  if type(ip) == "table" then ip = ip[1] end
  lan_cidr = cidr_from(ip, mask)
end

local include_lan = (uci:get("juliang_fastacl", "main", "include_lan") or "1") ~= "0"

local ignore = {
  wan=true, wan6=true, loopback=true, wwan=true
}

local by_net = {}
uci:foreach("wireless", "wifi-iface", function(s)
  if tostring(s.disabled or "0") ~= "1" and tostring(s.mode or "ap") == "ap" then
    local ssid = s.ssid or s[".name"] or "WiFi"
    for _, net in ipairs(split_words(s.network)) do
      if not ignore[net] and (net ~= "lan" or include_lan) then
        local cidr, router_ip = network_ipv4(net)
        if cidr and (net == "lan" or cidr ~= lan_cidr) then
          local item = by_net[net]
          if not item then
            item = {
              network = net,
              subnet = cidr,
              router_ip = router_ip or "",
              ssids = {},
              is_lan = (net == "lan")
            }
            by_net[net] = item
          end
          local found=false
          for _,v in ipairs(item.ssids) do if v == ssid then found=true break end end
          if not found then item.ssids[#item.ssids+1]=ssid end
        end
      end
    end
  end
end)

-- The main LAN also represents wired LAN clients. Include it even if the
-- main SSID is temporarily down, as long as the LAN IPv4 network exists.
if include_lan and lan_cidr and not by_net.lan then
  local cidr, router_ip = network_ipv4("lan")
  if cidr then
    by_net.lan = {
      network = "lan",
      subnet = cidr,
      router_ip = router_ip or "",
      ssids = {},
      is_lan = true
    }
  end
end

local items = {}
for _, item in pairs(by_net) do
  if item.is_lan then
    local wifi = table.concat(item.ssids, " / ")
    if wifi ~= "" then
      item.ssid = "主网络 · " .. wifi .. " · 有线LAN"
    else
      item.ssid = "主网络 · 有线LAN"
    end
    item._main_lan = true
  else
    item.ssid = table.concat(item.ssids, " / ")
    item._main_lan = false
  end
  item._sort = ip_to_num((item.subnet or ""):match("^([^/]+)$") or (item.subnet or ""):match("^([^/]+)/")) or 0
  items[#items+1] = item
end

-- Keep the main LAN last so existing A1..An slot numbers/ports do not shift.
table.sort(items, function(a,b)
  if a._main_lan ~= b._main_lan then return not a._main_lan end
  if a._sort == b._sort then return a.network < b.network end
  return a._sort < b._sort
end)

local old = {}
uci:foreach("juliang_fastacl", "ap", function(s)
  local data = {
    node = s.node,
    dns_mode = s.dns_mode,
    dns_server = s.dns_server,
    dns_tls_server_name = s.dns_tls_server_name,
    dns_path = s.dns_path
  }
  if s.network and s.network ~= "" then old["net:" .. s.network] = data end
  if s.subnet and s.subnet ~= "" then old["subnet:" .. s.subnet] = data end
end)

-- Discovery must be transactional. During early boot WiFi/netifd may not be
-- ready yet. Never erase a working persistent FastACL topology on a 0-result scan.
if #items == 0 then
  io.write(jsonc.stringify({ ok = false, count = 0, aps = {}, preserved = true, error = "NO_AP_READY" }, true))
  os.exit(2)
end

-- Remove only AP slot sections after we already have a valid replacement set.
local dels = {}
uci:foreach("juliang_fastacl", "ap", function(s) dels[#dels+1]=s[".name"] end)
for _,name in ipairs(dels) do uci:delete("juliang_fastacl", name) end

for i,item in ipairs(items) do
  local sec = "ap" .. i
  uci:section("juliang_fastacl", "ap", sec, {
    slot = tostring(i),
    network = item.network,
    ssid = item.ssid,
    subnet = item.subnet,
    router_ip = item.router_ip or "",
    socks_port = tostring(13100+i),
    preproxy_port = tostring(14100+i)
  })
  local prev = old["net:"..item.network] or old["subnet:"..item.subnet]
  if prev then
    if prev.node and prev.node ~= "" then uci:set("juliang_fastacl", sec, "node", prev.node) end
    if prev.dns_mode and prev.dns_mode ~= "" then uci:set("juliang_fastacl", sec, "dns_mode", prev.dns_mode) end
    if prev.dns_server and prev.dns_server ~= "" then uci:set("juliang_fastacl", sec, "dns_server", prev.dns_server) end
    if prev.dns_tls_server_name and prev.dns_tls_server_name ~= "" then uci:set("juliang_fastacl", sec, "dns_tls_server_name", prev.dns_tls_server_name) end
    if prev.dns_path and prev.dns_path ~= "" then uci:set("juliang_fastacl", sec, "dns_path", prev.dns_path) end
  end
end
uci:set("juliang_fastacl", "main", "ap_count", tostring(#items))
uci:commit("juliang_fastacl")

io.write(jsonc.stringify({ ok = (#items > 0), count = #items, aps = items }, true))
