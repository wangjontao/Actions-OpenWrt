#!/usr/bin/lua

local jsonc = require "luci.jsonc"
local uci = require("uci").cursor()

local DB = "/etc/fastc/nodes.json"
local GROUP_DB = "/etc/fastc/groups.json"
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
local function list_has(t,v)
  for _,x in ipairs(t) do if x==v then return true end end
  return false
end

local nodes=parse_json(DB,{})
local groups=parse_json(GROUP_DB,{})
local byid={}
for _,n in ipairs(nodes) do byid[tostring(n.id or "")]=n end

local parsed,invalid={},{}
local supported_scheme={vless=true,socks5=true,socks5h=true,socks=true,http=true,trojan=true}
for _,n in ipairs(nodes) do
  local id=tostring(n.id or "")
  local u,err=split_uri(n.raw or "")
  if id=="" then invalid[id]="BAD_ID"
  elseif not u then invalid[id]=err
  elseif not supported_scheme[u.scheme] then invalid[id]="RUNTIME_UNSUPPORTED:"..tostring(u.scheme)
  elseif u.scheme=="vless" and pct(u.auth)=="" then invalid[id]="VLESS_UUID_MISSING"
  elseif u.scheme=="vless" and u.query.security=="reality" and (not u.query.pbk or u.query.pbk=="") then invalid[id]="REALITY_PUBLIC_KEY_MISSING"
  elseif u.scheme=="trojan" and u.auth=="" then invalid[id]="TROJAN_PASSWORD_MISSING"
  else parsed[id]=u end
end

local function chain_error(id)
  local seen={}; local cur=id
  while cur and cur~="" do
    if seen[cur] then return "CHAIN_CYCLE" end
    seen[cur]=true
    local n=byid[cur]; if not n then return "CHAIN_NODE_MISSING:"..cur end
    if not parsed[cur] then return invalid[cur] or ("CHAIN_NODE_UNSUPPORTED:"..cur) end
    cur=tostring(n.chain or "")
  end
  return nil
end
for id,_ in pairs(parsed) do
  local n=byid[id]
  if n and n.chain and tostring(n.chain)~="" then
    if tostring(n.chain)==id then invalid[id]="CHAIN_SELF"
    else local e=chain_error(id); if e then invalid[id]=e end end
  end
end
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
  local chain=tostring(n.chain or "")
  if chain~="" then add(lines,"    dialer-proxy: "..yq(chain)) end
end

local tproxy=tonumber(uci:get("fastc","main","tproxy_port") or "7895") or 7895
local dnsport=tonumber(uci:get("fastc","main","dns_port") or "1053") or 1053
local probe_base=tonumber(uci:get("fastc","main","probe_port_base") or "18100") or 18100
local node_probe_base=tonumber(uci:get("fastc","main","node_probe_port_base") or "18200") or 18200
local controller=uci:get("fastc","main","controller") or "127.0.0.1:9097"
local lines={
  "# Generated by FastC 0.1.6-dev. Do not edit by hand.",
  "mode: rule","log-level: info","allow-lan: true","bind-address: \"*\"","ipv6: false",
  "unified-delay: true","tcp-concurrent: true",
  "profile:","  store-selected: false","  store-fake-ip: false",
  "tproxy-port: "..tostring(tproxy),
  "external-controller: "..controller,
  "dns:","  enable: true","  listen: 127.0.0.1:"..tostring(dnsport),"  ipv6: false","  enhanced-mode: redir-host",
  "  default-nameserver:","    - 1.1.1.1","    - 8.8.8.8",
  "  proxy-server-nameserver:","    - 1.1.1.1","    - 8.8.8.8",
  "  nameserver:","    - https://1.1.1.1/dns-query#FASTC-DNS-RESOLVER","    - https://8.8.8.8/dns-query#FASTC-DNS-RESOLVER",
  "proxies:"
}

local supported,rejected={},{}
for _,n in ipairs(nodes) do
  local id=tostring(n.id or "")
  if parsed[id] then emit_proxy(lines,n,parsed[id]); supported[#supported+1]=id
  else rejected[#rejected+1]={id=id,error=invalid[id] or "UNSUPPORTED"} end
end
-- Client port-53 traffic is TPROXY'ed into mihomo. This built-in DNS outbound
-- hands that request to mihomo's internal DNS module instead of trying to
-- proxy the router/gateway address (for example 172.16.1.1:53) remotely.
add(lines,"  - name: \"FASTC-DNS-HIJACK\"")
add(lines,"    type: dns")
local supported_map={}; for _,id in ipairs(supported) do supported_map[id]=true end

add(lines,"proxy-groups:")
local selected_map={}
for i=1,20 do
  local g="A"..i; local members={}
  for _,n in ipairs(nodes) do if n.group==g and supported_map[tostring(n.id)] then members[#members+1]=tostring(n.id) end end
  local wanted=tostring(groups[g] or "")
  local chosen=(#members>0 and members[1] or "REJECT")
  if wanted~="" and list_has(members,wanted) then chosen=wanted end
  selected_map[g]=chosen
  add(lines,"  - name: "..yq("FASTC-"..g)); add(lines,"    type: select")
  add(lines,"    default-selected: "..yq(chosen))
  add(lines,"    proxies:")
  if #members==0 then add(lines,"      - REJECT") else
    for _,m in ipairs(members) do add(lines,"      - "..yq(m)) end
    add(lines,"      - REJECT")
  end
end

-- DNS resolver traffic itself must not fall back to the router's WAN.
-- It uses the first available imported proxy; node-hostname bootstrap DNS is
-- handled separately by proxy-server-nameserver above.
local dns_chosen=(#supported>0 and supported[1] or "REJECT")
add(lines,"  - name: \"FASTC-DNS-RESOLVER\"")
add(lines,"    type: select")
add(lines,"    default-selected: "..yq(dns_chosen))
add(lines,"    proxies:")
if #supported==0 then add(lines,"      - REJECT") else
  for _,id in ipairs(supported) do add(lines,"      - "..yq(id)) end
  add(lines,"      - REJECT")
end

-- Local-only SOCKS listeners for current A-group exit verification.
add(lines,"listeners:")
for i=1,20 do
  add(lines,"  - name: "..yq("fastc-a"..i.."-probe"))
  add(lines,"    type: socks")
  add(lines,"    listen: 127.0.0.1")
  add(lines,"    port: "..tostring(probe_base+i))
  add(lines,"    udp: false")
  add(lines,"    proxy: "..yq("FASTC-A"..i))
end

-- Every supported node also gets a deterministic local-only SOCKS probe.
for _,id in ipairs(supported) do
  local n=tonumber(id:match("^n(%d+)$") or "")
  if n and node_probe_base+n<=65535 then
    add(lines,"  - name: "..yq("fastc-"..id.."-probe"))
    add(lines,"    type: socks")
    add(lines,"    listen: 127.0.0.1")
    add(lines,"    port: "..tostring(node_probe_base+n))
    add(lines,"    udp: false")
    add(lines,"    proxy: "..yq(id))
  end
end

add(lines,"rules:")
-- DNS hijack must run before source-group routing. Otherwise a DNS query sent
-- to the router gateway would be treated as a remote destination through the
-- selected proxy and fail.
add(lines,"  - DST-PORT,53,FASTC-DNS-HIJACK")
local subnets={}
for i=1,20 do
  local subnet=uci:get("juliang_fastacl","ap"..i,"subnet") or ""
  if subnet~="" then subnets[i]=subnet; add(lines,"  - SRC-IP-CIDR,"..subnet..",FASTC-A"..i) end
end
add(lines,"  - MATCH,DIRECT"); add(lines,"")

os.execute("mkdir -p /etc/fastc")
writeall(OUT,table.concat(lines,"\n"))
io.write(jsonc.stringify({ok=true,config=OUT,supported=supported,rejected=rejected,total=#nodes,subnets=subnets,selected=selected_map,dns_resolver=dns_chosen,probe_port_base=probe_base,node_probe_port_base=node_probe_base},true),"\n")
