local jsonc = require "luci.jsonc"
local uci = require("luci.model.uci").cursor()
local node = arg[1] or ""
local port = tonumber(arg[2] or "0")
local outfile = arg[3] or ""
local preproxy_port = tonumber(arg[4] or "0")
if node == "" or port == 0 or outfile == "" then os.exit(2) end
local n = uci:get_all("passwall2", node)
if not n then os.exit(3) end
local t = string.lower(n.protocol or n.type or "")
local out
if t == "socks" then
  out = {
    type = "socks", tag = "proxy", server = n.address, server_port = tonumber(n.port), version = "5",
    username = n.username, password = n.password
  }
elseif t == "http" then
  out = {
    type = "http", tag = "proxy", server = n.address, server_port = tonumber(n.port),
    username = n.username, password = n.password
  }
else
  os.exit(4)
end
local outbounds = {}
if preproxy_port and preproxy_port > 0 then
  outbounds[#outbounds + 1] = {
    type = "socks",
    tag = "preproxy",
    server = "127.0.0.1",
    server_port = preproxy_port,
    version = "5"
  }
  out.detour = "preproxy"
end
outbounds[#outbounds + 1] = out

local conf = {
  log = { level = "error" },
  inbounds = { { type = "socks", tag = "in", listen = "127.0.0.1", listen_port = port } },
  outbounds = outbounds,
  route = { final = "proxy" }
}
local f = assert(io.open(outfile, "w"))
f:write(jsonc.stringify(conf, true))
f:close()
