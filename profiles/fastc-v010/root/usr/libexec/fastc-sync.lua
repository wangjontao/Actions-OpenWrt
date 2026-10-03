#!/usr/bin/lua

local jsonc=require "luci.jsonc"
local DB="/etc/fastc/nodes.json"
local GROUP_DB="/etc/fastc/groups.json"
local TOPO="/etc/fastc/topology.json"
local API="http://127.0.0.1:9097"

local function read_json(path,fallback)
  local f=io.open(path,"rb"); if not f then return fallback end
  local raw=f:read("*a") or ""; f:close()
  local ok,obj=pcall(jsonc.parse,raw)
  if ok and type(obj)=="table" then return obj end
  return fallback
end
local function shq(s) return "'"..tostring(s or ""):gsub("'","'\\''").."'" end
local function put_select(group,node)
  local payload=jsonc.stringify({name=node})
  local cmd="curl -fsS --connect-timeout 1 --max-time 2 -o /dev/null -X PUT -H 'Content-Type: application/json' --data "..shq(payload).." "..shq(API.."/proxies/FASTC-"..group)
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
  for _=1,12 do
    local p=snapshot()
    if p then return p end
    os.execute("sleep 0.2")
  end
  return nil
end

local nodes=read_json(DB,{})
local groups=read_json(GROUP_DB,{})
local topo=read_json(TOPO,{aps={}})
local aps=type(topo.aps)=="table" and topo.aps or {}
local members={}
for _,ap in ipairs(aps) do
  local g=tostring(ap.group or ("A"..tostring(ap.slot or "")))
  if g~="" then members[g]={} end
end
for _,n in ipairs(nodes) do
  local g=tostring(n.group or "")
  local id=tostring(n.id or "")
  if members[g] and id:match("^n%d+$") then members[g][#members[g]+1]=id end
end

if #aps==0 then
  io.write(jsonc.stringify({ok=false,error="TOPOLOGY_EMPTY"},true),"\n")
  os.exit(1)
end

local proxies=wait_snapshot()
if not proxies then
  io.write(jsonc.stringify({ok=false,error="MIHOMO_API_NOT_READY"},true),"\n")
  os.exit(1)
end

local wanted_map={}
local changed_groups={}
for _,ap in ipairs(aps) do
  local g=tostring(ap.group or ("A"..tostring(ap.slot or "")))
  local wanted=tostring(groups[g] or "")
  local exists=false
  for _,id in ipairs(members[g] or {}) do if id==wanted then exists=true break end end
  if not exists then wanted=((members[g] or {})[1] or "REJECT") end
  wanted_map[g]=wanted
  local obj=proxies["FASTC-"..g]
  local now=(type(obj)=="table" and tostring(obj.now or "")) or ""
  if now~=wanted then changed_groups[#changed_groups+1]=g end
end

local put_ok={}
for _,g in ipairs(changed_groups) do
  put_ok[g]=put_select(g,wanted_map[g])
end

-- Only fetch a second snapshot when something actually changed.
if #changed_groups>0 then
  local verify=snapshot()
  if verify then proxies=verify end
end

local out={ok=true,changed=#changed_groups,groups={}}
for _,ap in ipairs(aps) do
  local g=tostring(ap.group or ("A"..tostring(ap.slot or "")))
  local wanted=wanted_map[g] or "REJECT"
  local obj=proxies["FASTC-"..g]
  local now=(type(obj)=="table" and tostring(obj.now or "")) or ""
  local was_changed=false
  for _,cg in ipairs(changed_groups) do if cg==g then was_changed=true break end end
  local ok=(not was_changed) or (put_ok[g]==true)
  out.groups[g]={wanted=wanted,now=now,synced=(ok and now==wanted) and true or false,changed=was_changed,ssid=ap.ssid or g,subnet=ap.subnet or ""}
end

io.write(jsonc.stringify(out,true),"\n")
