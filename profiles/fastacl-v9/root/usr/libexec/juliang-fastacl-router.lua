local jsonc = require "luci.jsonc"
local uci = require("luci.model.uci").cursor()
local cfg = "juliang_fastacl"
local port = tonumber(uci:get(cfg, "main", "tproxy_port") or "12345")
local dns_mode = uci:get(cfg, "main", "dns_mode") or "doh"
local dns_addr = uci:get(cfg, "main", "dns_server") or "1.1.1.1"
local dns_tls_name = uci:get(cfg, "main", "dns_tls_server_name") or "cloudflare-dns.com"
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
      name = s[".name"] or ("ap" .. slot),
      dns_mode = s.dns_mode or dns_mode,
      dns_server = s.dns_server or dns_addr,
      dns_tls_server_name = s.dns_tls_server_name or dns_tls_name,
      dns_path = s.dns_path or dns_path
    }
  end
end)
table.sort(aps, function(a,b) return a.slot < b.slot end)

if #aps == 0 then
  io.stderr:write("FastACL: no discovered AP networks\n")
  os.exit(2)
end

local outbounds = { { type = "direct", tag = "direct" } }
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
  local dns_server
  if a.dns_mode == "tcp" then
    dns_server = {
      type = "tcp",
      tag = "dns-" .. tag,
      server = a.dns_server,
      server_port = 53,
      detour = tag
    }
  else
    dns_server = {
      type = "https",
      tag = "dns-" .. tag,
      server = a.dns_server,
      server_port = 443,
      path = a.dns_path,
      tls = {
        enabled = true,
        server_name = a.dns_tls_server_name
      },
      detour = tag
    }
  end
  dns_servers[#dns_servers + 1] = dns_server
  dns_rules[#dns_rules + 1] = {
    source_ip_cidr = { a.subnet },
    action = "route",
    server = "dns-" .. tag
  }
  route_rules[#route_rules + 1] = {
    source_ip_cidr = { a.subnet },
    port = { 53 },
    action = "hijack-dns"
  }
  route_rules[#route_rules + 1] = {
    source_ip_cidr = { a.subnet },
    action = "route",
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
      listen_port = port
    }
  },
  outbounds = outbounds,
  route = {
    rules = route_rules,
    final = "direct"
  }
}

io.write(jsonc.stringify(conf, true))
