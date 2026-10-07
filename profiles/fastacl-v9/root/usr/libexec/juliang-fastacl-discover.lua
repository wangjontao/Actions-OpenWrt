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
local ignore = { wan=true, wan6=true, loopback=true, wwan=true }
local by_net = {}

local function add_network(net, ssid, source)
  if not net or net == "" or ignore[net] or (net == "lan" and not include_lan) then return false end
  local cidr, router_ip = network_ipv4(net)
  if not cidr or (net ~= "lan" and cidr == lan_cidr) then return false end

  local item = by_net[net]
  if not item then
    item = {
      network = net,
      subnet = cidr,
      router_ip = router_ip or "",
      ssids = {},
      sources = {},
      is_lan = (net == "lan")
    }
    by_net[net] = item
  end

  if ssid and ssid ~= "" then
    local found=false
    for _,v in ipairs(item.ssids) do if v == ssid then found=true break end end
    if not found then item.ssids[#item.ssids+1]=ssid end
  end
  if source and source ~= "" then item.sources[source]=true end
  return true
end

-- 1) Normal UCI wireless mapping.
uci:foreach("wireless", "wifi-iface", function(s)
  if tostring(s.disabled or "0") ~= "1" and tostring(s.mode or "ap") == "ap" then
    local ssid = s.ssid or s[".name"] or "WiFi"
    for _, net in ipairs(split_words(s.network)) do
      add_network(net, ssid, "uci")
    end
  end
end)

-- 2) Runtime/MTWiFi SSID-name fallback. AX6000/S20L closed MTWiFi can expose
-- A1..A20 before netifd has completed wifi-iface -> network association.
local runtime_ssids = {}
local runtime_cmd = [[
(
  if command -v iwinfo >/dev/null 2>&1; then
    for i in $(ls /sys/class/net 2>/dev/null); do
      iwinfo "$i" info 2>/dev/null | sed -n 's/.*ESSID: "\(.*\)".*/\1/p'
    done
  fi
  if command -v iwconfig >/dev/null 2>&1; then
    iwconfig 2>/dev/null | sed -n 's/.*ESSID:"\([^"]*\)".*/\1/p'
  fi
  for f in /etc/wireless/mediatek/*.dat /etc/wireless/*.dat; do
    [ -f "$f" ] || continue
    sed -n 's/^SSID[0-9][0-9]*=//p' "$f"
  done
) | sed '/^[[:space:]]*$/d' | sort -u
]]
for ssid in (sys.exec(runtime_cmd) or ""):gmatch("[^\r\n]+") do
  runtime_ssids[ssid] = true
end

for i=1,20 do
  local ssid = "A" .. tostring(i)
  if runtime_ssids[ssid] then
    add_network("a" .. tostring(i), ssid, "runtime")
  end
end

-- The main LAN also represents wired LAN clients.
if include_lan and lan_cidr and not by_net.lan then
  add_network("lan", nil, "lan")
end

local items = {}
for _, item in pairs(by_net) do
  if item.is_lan then
    local wifi = table.concat(item.ssids, " / ")
    if wifi ~= "" then item.ssid = "主网络 · " .. wifi .. " · 有线LAN"
    else item.ssid = "主网络 · 有线LAN" end
    item._main_lan = true
  else
    item.ssid = table.concat(item.ssids, " / ")
    item._main_lan = false
  end
  item._sort = ip_to_num((item.subnet or ""):match("^([^/]+)/")) or 0
  items[#items+1] = item
end

table.sort(items, function(a,b)
  if a._main_lan ~= b._main_lan then return not a._main_lan end
  if a._sort == b._sort then return a.network < b.network end
  return a._sort < b._sort
end)

local old = {}
local old_count = 0
uci:foreach("juliang_fastacl", "ap", function(s)
  old_count = old_count + 1
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

-- Discovery is transactional. A 0-result scan or a partial early-boot scan
-- must never shrink a working AX6000/S20L topology. Use discover-force only
-- when the operator intentionally removed SSIDs and wants to shrink AP slots.
if #items == 0 then
  io.write(jsonc.stringify({ ok=false, count=0, previous_count=old_count, aps={}, preserved=true, error="NO_AP_READY" }, true))
  os.exit(2)
end

local force = (os.getenv("JFA_DISCOVER_FORCE") == "1")
if old_count > 0 and #items < old_count and not force then
  io.write(jsonc.stringify({
    ok=false,
    count=#items,
    previous_count=old_count,
    aps=items,
    preserved=true,
    error="PARTIAL_AP_READY",
    hint="run juliang-fastacl wifi-detect; retry discover after A-series SSIDs are ready; use discover-force only for intentional AP removal"
  }, true))
  os.exit(3)
end

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

io.write(jsonc.stringify({ ok=(#items>0), count=#items, previous_count=old_count, aps=items, forced=force }, true))
