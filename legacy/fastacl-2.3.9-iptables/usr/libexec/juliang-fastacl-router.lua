local jsonc = require "luci.jsonc"
local uci = require("luci.model.uci").cursor()
local cfg = "juliang_fastacl"
local port = tonumber(uci:get(cfg, "main", "tproxy_port") or "12345")
local dns_mode = uci:get(cfg, "main", "dns_mode") or "doh"
local dns_addr = uci:get(cfg, "main", "dns_server") or "1.1.1.1"
local dns_path = uci:get(cfg, "main", "dns_path") or "/dns-query"

local aps = {}
uci:foreach(cfg, "ap", function(s)
  local slot = tonumber(s.slot or (s[".name"] or ""):match("^ap(%d+)$"))
  local subnet = s.subnet
  local sport = tonumber(s.socks_port)
  if slot and subnet and subnet ~= "" and sport then
    aps[#aps + 1] = {
      slot = slot,
      subnet = subnet,
      sport = sport,
      dns_mode = s.dns_mode or dns_mode,
      dns_server = s.dns_server or dns_addr,
      dns_path = s.dns_path or dns_path
    }
  end
end)
table.sort(aps, function(a,b) return a.slot < b.slot end)

if #aps == 0 then
  io.stderr:write("FastACL: no discovered AP networks\n")
  os.exit(2)
end

local outbounds = {
  { type = "direct", tag = "direct" },
  { type = "dns", tag = "dns-out" }
}
local route_rules = {}
local dns_servers = {}
local dns_rules = {}

for _, a in ipairs(aps) do
  local tag = "ap" .. a.slot
  outbounds[#outbounds + 1] = {
    type = "socks",
    tag = tag,
    server = "127.0.0.1",
    server_port = a.sport,
    version = "5"
  }

  local address
  if a.dns_mode == "tcp" then
    address = "tcp://" .. a.dns_server
  else
    address = "https://" .. a.dns_server .. (a.dns_path or "/dns-query")
  end
  dns_servers[#dns_servers + 1] = {
    tag = "dns-" .. tag,
    address = address,
    detour = tag
  }
  dns_rules[#dns_rules + 1] = {
    source_ip_cidr = { a.subnet },
    server = "dns-" .. tag
  }

  route_rules[#route_rules + 1] = {
    source_ip_cidr = { a.subnet },
    port = { 53 },
    outbound = "dns-out"
  }
  route_rules[#route_rules + 1] = {
    source_ip_cidr = { a.subnet },
    outbound = tag
  }
end

local conf = {
  log = { level = "warn", timestamp = true },
  dns = {
    servers = dns_servers,
    rules = dns_rules,
    final = dns_servers[1] and dns_servers[1].tag or nil
  },
  inbounds = {
    {
      type = "tproxy",
      tag = "jfa-tproxy",
      listen = "0.0.0.0",
      listen_port = port,
      sniff = true
    }
  },
  outbounds = outbounds,
  route = {
    rules = route_rules,
    final = "direct"
  }
}

io.write(jsonc.stringify(conf, true))
