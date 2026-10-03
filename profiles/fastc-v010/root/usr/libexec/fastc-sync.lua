#!/usr/bin/lua

local jsonc=require "luci.jsonc"
local BIND_DB="/etc/fastc/bindings.json"
local CHAIN_DB="/etc/fastc/chains.json"
local TOPO_DB="/etc/fastc/topology.json"
local API="http://127.0.0.1:9097"

local function read_json(path,fallback)
  local f=io.open(path,"rb"); if not f then return fallback end
  local raw=f:read("*a") or ""; f:close()
  local ok,obj=pcall(jsonc.parse,raw)
  if ok and type(obj)=="table" then return obj end
  return fallback
end
local function shq(s) return "'"..tostring(s or ""):gsub("'","'\\''").."'" end
local function trim(s) return (tostring(s or ""):gsub("^%s+",""):gsub("%s+$","")) end
local function put_select(name,node)
  local payload=jsonc.stringify({name=node})
  local cmd="curl -fsS --connect-timeout 1 --max-time 2 -o /dev/null -X PUT -H 'Content-Type: application/json' --data "..shq(payload).." "..shq(API.."/proxies/"..name).." 2>/dev/null"
  return os.execute(cmd)==0
end
local function snapshot()
  local p=io.popen("curl -fsS --connect-timeout 1 --max-time 2 "..shq(API.."/proxies").." 2>/dev/null")
  if not p then return nil end
  local raw=p:read("*a") or ""; p:close()
  local ok,obj=pcall(jsonc.parse,raw)
  if not ok or type(obj)~="table" or type(obj.proxies)~="table" then return nil end
  return obj.proxies
end
local function wait_snapshot()
  for _=1,8 do
    local p=snapshot(); if p then return p end
    os.execute("sleep 0.2")
  end
  return nil
end
local function binding_node(bindings,g)
  local b=bindings[g]
  if type(b)=="table" then return tostring(b.node or "") end
  return tostring(b or "")
end
local function chain_via(chains,id)
  local c=chains[id]
  if type(c)=="table" then return tostring(c.via or "") end
  return tostring(c or "")
end

local bindings=read_json(BIND_DB,{})
local chains=read_json(CHAIN_DB,{})
local topo=read_json(TOPO_DB,{aps={}})
local aps=type(topo.aps)=="table" and topo.aps or {}
if #aps==0 then
  io.write(jsonc.stringify({ok=false,error="TOPOLOGY_EMPTY"},true),"\n")
  os.exit(1)
end
local proxies=wait_snapshot()
if not proxies then
  io.write(jsonc.stringify({ok=false,error="MIHOMO_API_NOT_READY"},true),"\n")
  os.exit(1)
end

local wanted={}
for _,ap in ipairs(aps) do
  local g=tostring(ap.group or ("A"..tostring(ap.slot or "")))
  local id=binding_node(bindings,g)
  if id=="" then id="REJECT" end
  wanted["FASTC-"..g]={kind="group",key=g,target=id,ssid=ap.ssid or g,subnet=ap.subnet or ""}
end
for id,_ in pairs(chains) do
  local name="FASTC-CHAIN-"..tostring(id)
  if proxies[name] then
    local via=chain_via(chains,id); if via=="" then via="DIRECT" end
    wanted[name]={kind="chain",key=id,target=via}
  end
end

local changed={}
for name,w in pairs(wanted) do
  local obj=proxies[name]
  local now=(type(obj)=="table" and tostring(obj.now or "")) or ""
  if now~=w.target then changed[#changed+1]={name=name,target=w.target} end
end
local put_ok={}
for _,x in ipairs(changed) do put_ok[x.name]=put_select(x.name,x.target) end
if #changed>0 then local p=snapshot(); if p then proxies=p end end

local out={ok=true,changed=#changed,synced=true,groups={},chains={}}
for name,w in pairs(wanted) do
  local obj=proxies[name]
  local now=(type(obj)=="table" and tostring(obj.now or "")) or ""
  local synced=(now==w.target)
  if not synced then out.synced=false end
  if w.kind=="group" then out.groups[w.key]={wanted=w.target,now=now,synced=synced,ssid=w.ssid,subnet=w.subnet}
  else out.chains[w.key]={wanted=w.target,now=now,synced=synced} end
end
io.write(jsonc.stringify(out,true),"\n")
if out.synced then os.exit(0) end
os.exit(1)
