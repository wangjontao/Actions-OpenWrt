#!/usr/bin/lua

local jsonc = require "luci.jsonc"
local uci = require("uci").cursor()

local DB = "/etc/fastc/nodes.json"
local BIND_DB = "/etc/fastc/bindings.json"
local CHAIN_DB = "/etc/fastc/chains.json"
local TOPO = "/etc/fastc/topology.json"
local OUT = "/etc/fastc/config.yaml"

local function readall(path)
  local f=io.open(path,"rb"); if not f then return nil end
  local s=f:read("*a"); f:close(); return s
end
local function writeall(path,data)
  local f=assert(io.open(path,"wb")); f:write(data); f:close()
end
local function trim(s) return (tostring(s or ""):gsub("^%s+",""):gsub("%s+$","")) end
local function pct(s)
  s=tostring(s or ""):gsub("%+"," ")
  return (s:gsub("%%(%x%x)",function(h)return string.char(tonumber(h,16))end))
end
local function yq(s)
  s=tostring(s or ""):gsub("\\","\\\\"):gsub('"','\\"'):gsub("\r",""):gsub("\n","\\n")
  return '"'..s..'"'
end
local function parse_json(path,fallback)
  local raw=readall(path); if not raw or raw=="" then return fallback end
  local ok,obj=pcall(jsonc.parse,raw); if ok and type(obj)=="table" then return obj end
  return fallback
end
local function parse_query(q)
  local out={}
  for kv in tostring(q or ""):gmatch("[^&]+") do
    local k,v=kv:match("^([^=]+)=(.*)$")
    if k then out[pct(k)]=pct(v) else out[pct(kv)]="" end
  end
  return out
end
local function split_uri(raw)
  raw=trim(raw); local base=raw:match("^(.-)#") or raw
  local scheme,rest=base:match("^([%w+.-]+)://(.+)$"); if not scheme then return nil,"BAD_URI" end
  scheme=scheme:lower()
  local before,q=rest:match("^(.-)%?(.*)$"); if before then rest=before else q="" end
  local auth,hostport=rest:match("^(.-)@(.+)$"); if not hostport then hostport,auth=rest,"" end
  local host,port
  if hostport:sub(1,1)=="[" then host,port=hostport:match("^%[([^%]]+)%]:(%d+)$") else host,port=hostport:match("^([^:]+):(%d+)$") end
  if not host or not port then return nil,"BAD_ADDRESS" end
  return {scheme=scheme,auth=auth or "",host=host,port=tonumber(port),query=parse_query(q)}
end
local function add(lines,s) lines[#lines+1]=s end

os.execute("lua /usr/libexec/fastc-discover.lua >/tmp/fastc-discover.json 2>/tmp/fastc-discover.log || true")
if not readall(BIND_DB) or not readall(CHAIN_DB) then
  os.execute("lua /usr/libexec/fastc-state.lua migrate >/tmp/fastc-state-migrate.json 2>/tmp/fastc-state-migrate.log || true")
end

local topology=parse_json(TOPO,{aps={}})
local aps=type(topology.aps)=="table" and topology.aps or {}
if #aps==0 then io.stderr:write("FastC topology unavailable: no discovered AP/network slots\n"); os.exit(2) end
local nodes=parse_json(DB,{})
local bindings=parse_json(BIND_DB,{})
local chains=parse_json(CHAIN_DB,{})
local byid={}
for _,n in ipairs(nodes) do byid[tostring(n.id or "")]=n end

local parsed,invalid={},{}
local supported_scheme={vless=true,socks5=true,socks5h=true,socks=true,http=true,trojan=true}
for _,n in ipairs(nodes) do
  local id=tostring(n.id or ""); local u,err=split_uri(n.raw or "")
  if id=="" then invalid[id]="BAD_ID"
  elseif not u then invalid[id]=err
  elseif not supported_scheme[u.scheme] then invalid[id]="RUNTIME_UNSUPPORTED:"..tostring(u.scheme)
  elseif u.scheme=="vless" and pct(u.auth)=="" then invalid[id]="VLESS_UUID_MISSING"
  elseif u.scheme=="vless" and u.query.security=="reality" and (not u.query.pbk or u.query.pbk=="") then invalid[id]="REALITY_PUBLIC_KEY_MISSING"
  elseif u.scheme=="trojan" and u.auth=="" then invalid[id]="TROJAN_PASSWORD_MISSING"
  else parsed[id]=u end
end

local function chain_via(id)
  local c=chains[id]
  if type(c)=="table" then return tostring(c.via or "") end
  return tostring(c or "")
end
local function chain_error(id)
  local seen={}; local cur=id
  while cur and cur~="" do
    if seen[cur] then return "CHAIN_CYCLE" end
    seen[cur]=true
    if not byid[cur] then return "CHAIN_NODE_MISSING:"..cur end
    if not parsed[cur] then return invalid[cur] or ("CHAIN_NODE_UNSUPPORTED:"..cur) end
    cur=chain_via(cur)
  end
  return nil
end
for id,_ in pairs(parsed) do local e=chain_error(id); if e then invalid[id]=e end end
for id,_ in pairs(invalid) do parsed[id]=nil end

local function emit_proxy(lines,n,u)
  local id=tostring(n.id)
  add(lines,"  - name: "..yq(id))
  if u.scheme=="vless" then
    add(lines,"    type: vless"); add(lines,"    server: "..yq(u.host)); add(lines,"    port: "..u.port)
    add(lines,"    uuid: "..yq(pct(u.auth))); add(lines,"    udp: true")
    if u.query.flow and u.query.flow~="" then add(lines,"    flow: "..yq(u.query.flow)) end
    add(lines,"    network: "..yq((u.query.type and u.query.type~="") and u.query.type or "tcp"))
    if u.query.security=="tls" or u.query.security=="reality" then
      add(lines,"    tls: true")
      if u.query.sni and u.query.sni~="" then add(lines,"    servername: "..yq(u.query.sni)) end
      if u.query.fp and u.query.fp~="" then add(lines,"    client-fingerprint: "..yq(u.query.fp)) end
    end
    if u.query.security=="reality" then
      add(lines,"    reality-opts:"); add(lines,"      public-key: "..yq(u.query.pbk))
      if u.query.sid and u.query.sid~="" then add(lines,"      short-id: "..yq(u.query.sid)) end
    end
  elseif u.scheme=="socks5" or u.scheme=="socks5h" or u.scheme=="socks" then
    local user,pass=u.auth:match("^([^:]*):(.*)$")
    add(lines,"    type: socks5"); add(lines,"    server: "..yq(u.host)); add(lines,"    port: "..u.port); add(lines,"    udp: true")
    if user and user~="" then add(lines,"    username: "..yq(pct(user))) end
    if pass and pass~="" then add(lines,"    password: "..yq(pct(pass))) end
  elseif u.scheme=="http" then
    local user,pass=u.auth:match("^([^:]*):(.*)$")
    add(lines,"    type: http"); add(lines,"    server: "..yq(u.host)); add(lines,"    port: "..u.port)
    if user and user~="" then add(lines,"    username: "..yq(pct(user))) end
    if pass and pass~="" then add(lines,"    password: "..yq(pct(pass))) end
  elseif u.scheme=="trojan" then
    add(lines,"    type: trojan"); add(lines,"    server: "..yq(u.host)); add(lines,"    port: "..u.port)
    add(lines,"    password: "..yq(pct(u.auth))); add(lines,"    udp: true")
    if u.query.sni and u.query.sni~="" then add(lines,"    sni: "..yq(u.query.sni)) end
    if u.query.fp and u.query.fp~="" then add(lines,"    client-fingerprint: "..yq(u.query.fp)) end
  end
  -- Chain relationship itself is now a selector. Changing the selected
  -- upstream does not require regenerating or reloading the main config.
  add(lines,"    dialer-proxy: "..yq("FASTC-CHAIN-"..id))
end

local tproxy=tonumber(uci:get("fastc","main","tproxy_port") or "7895") or 7895
local dnsport=tonumber(uci:get("fastc","main","dns_port") or "1053") or 1053
local node_probe_port=tonumber(uci:get("fastc","main","node_probe_port") or "18200") or 18200
local controller=uci:get("fastc","main","controller") or "127.0.0.1:9097"
local lines={
  "# Generated by FastC 0.2.0-dev. Hot-control architecture.",
  "mode: rule","log-level: warning","allow-lan: true","bind-address: \"*\"","ipv6: false",
  "find-process-mode: off","unified-delay: true","tcp-concurrent: true",
  "profile:","  store-selected: false","  store-fake-ip: false",
  "tproxy-port: "..tostring(tproxy),"external-controller: "..controller,
  "dns:","  enable: true","  listen: 127.0.0.1:"..tostring(dnsport),"  ipv6: false","  enhanced-mode: redir-host",
  "  default-nameserver:","    - 1.1.1.1","    - 8.8.8.8",
  "  proxy-server-nameserver:","    - 1.1.1.1","    - 8.8.8.8",
  "  nameserver:","    - https://1.1.1.1/dns-query#FASTC-DNS-RESOLVER","    - https://8.8.8.8/dns-query#FASTC-DNS-RESOLVER",
  "proxies:"
}
local supported,rejected={},{}; local supported_map={}
for _,n in ipairs(nodes) do local id=tostring(n.id or ""); if parsed[id] then emit_proxy(lines,n,parsed[id]); supported[#supported+1]=id; supported_map[id]=true else rejected[#rejected+1]={id=id,error=invalid[id] or "UNSUPPORTED"} end end
add(lines,"  - name: \"FASTC-DNS-HIJACK\""); add(lines,"    type: dns")

-- Relay pool is intentionally small: only explicit relay=true nodes and nodes
-- already referenced as a chain upstream. This avoids O(N^2) config growth when
-- hundreds of SOCKS5 endpoints are imported.
local relay_set={}
for _,n in ipairs(nodes) do local id=tostring(n.id or ""); if supported_map[id] and (n.relay==true or tostring(n.relay or "")=="1") then relay_set[id]=true end end
for _,c in pairs(chains) do local via=type(c)=="table" and tostring(c.via or "") or tostring(c or ""); if supported_map[via] then relay_set[via]=true end end
local relays={}
for _,n in ipairs(nodes) do local id=tostring(n.id or ""); if relay_set[id] then relays[#relays+1]=id end end

add(lines,"proxy-groups:")
-- Per-node chain selectors: ordinary chain switching is now one API PUT.
for _,id in ipairs(supported) do
  local via=chain_via(id); local chosen=(via~="" and relay_set[via] and via~=id) and via or "DIRECT"
  add(lines,"  - name: "..yq("FASTC-CHAIN-"..id)); add(lines,"    type: select"); add(lines,"    default-selected: "..yq(chosen)); add(lines,"    proxies:"); add(lines,"      - DIRECT")
  for _,rid in ipairs(relays) do if rid~=id then add(lines,"      - "..yq(rid)) end end
end

local selected_map={}
for _,ap in ipairs(aps) do
  local g=tostring(ap.group or ("A"..tostring(ap.slot or ""))); local b=bindings[g]
  local wanted=type(b)=="table" and tostring(b.node or "") or tostring(b or "")
  local chosen=(wanted~="" and supported_map[wanted]) and wanted or "REJECT"; selected_map[g]=chosen
  add(lines,"  - name: "..yq("FASTC-"..g)); add(lines,"    type: select"); add(lines,"    default-selected: "..yq(chosen)); add(lines,"    proxies:")
  for _,id in ipairs(supported) do add(lines,"      - "..yq(id)) end; add(lines,"      - REJECT")
end
local dns_chosen="REJECT"
for _,ap in ipairs(aps) do local g=tostring(ap.group or ("A"..tostring(ap.slot or ""))); local b=bindings[g]; local id=type(b)=="table" and tostring(b.node or "") or tostring(b or ""); if supported_map[id] then dns_chosen=id; break end end
if dns_chosen=="REJECT" and #supported>0 then dns_chosen=supported[1] end
add(lines,"  - name: \"FASTC-DNS-RESOLVER\""); add(lines,"    type: select"); add(lines,"    default-selected: "..yq(dns_chosen)); add(lines,"    proxies:"); for _,id in ipairs(supported) do add(lines,"      - "..yq(id)) end; add(lines,"      - REJECT")
add(lines,"  - name: \"FASTC-NODE-PROBE\""); add(lines,"    type: select"); add(lines,"    default-selected: "..yq((#supported>0 and supported[1] or "REJECT"))); add(lines,"    proxies:"); for _,id in ipairs(supported) do add(lines,"      - "..yq(id)) end; add(lines,"      - REJECT")

add(lines,"listeners:")
add(lines,"  - name: \"fastc-node-probe\""); add(lines,"    type: socks"); add(lines,"    listen: 127.0.0.1"); add(lines,"    port: "..tostring(node_probe_port)); add(lines,"    udp: false"); add(lines,"    proxy: \"FASTC-NODE-PROBE\"")
add(lines,"rules:"); add(lines,"  - DST-PORT,53,FASTC-DNS-HIJACK")
local subnets={}
for _,ap in ipairs(aps) do local g=tostring(ap.group or ("A"..tostring(ap.slot or ""))); local subnet=tostring(ap.subnet or ""); if subnet~="" then subnets[g]=subnet; add(lines,"  - SRC-IP-CIDR,"..subnet..",FASTC-"..g) end end
add(lines,"  - MATCH,DIRECT"); add(lines,"")
os.execute("mkdir -p /etc/fastc"); writeall(OUT,table.concat(lines,"\n"))
io.write(jsonc.stringify({ok=true,version="0.2.0-dev",config=OUT,supported=supported,rejected=rejected,total=#nodes,topology=topology,subnets=subnets,selected=selected_map,dns_resolver=dns_chosen,node_probe_port=node_probe_port,bindings=bindings,chains=chains,relays=relays},true),"\n")
