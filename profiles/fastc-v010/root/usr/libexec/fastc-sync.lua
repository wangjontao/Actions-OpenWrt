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
local function api_ready()
  return os.execute("curl -fsS --connect-timeout 1 --max-time 1 "..shq(API.."/version").." >/dev/null 2>&1")==0
end
local function wait_api()
  for _=1,12 do if api_ready() then return true end os.execute("sleep 0.2") end
  return false
end
local function put_select(group,node)
  local payload=jsonc.stringify({name=node})
  local cmd="curl -fsS --connect-timeout 1 --max-time 2 -o /dev/null -X PUT -H 'Content-Type: application/json' --data "..shq(payload).." "..shq(API.."/proxies/FASTC-"..group)
  return os.execute(cmd)==0
end
local function get_now(group)
  local p=io.popen("curl -fsS --connect-timeout 1 --max-time 2 "..shq(API.."/proxies/FASTC-"..group).." 2>/dev/null")
  if not p then return nil end
  local raw=p:read("*a") or ""; p:close()
  local ok,obj=pcall(jsonc.parse,raw)
  if ok and type(obj)=="table" then return tostring(obj.now or "") end
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
if not wait_api() then
  io.write(jsonc.stringify({ok=false,error="MIHOMO_API_NOT_READY"},true),"\n")
  os.exit(1)
end

local out={ok=true,changed=0,groups={}}
for _,ap in ipairs(aps) do
  local g=tostring(ap.group or ("A"..tostring(ap.slot or "")))
  local wanted=tostring(groups[g] or "")
  local exists=false
  for _,id in ipairs(members[g] or {}) do if id==wanted then exists=true break end end
  if not exists then wanted=((members[g] or {})[1] or "REJECT") end

  local now=get_now(g) or ""
  local changed=false
  local ok=true
  if now~=wanted then
    ok=put_select(g,wanted)
    if ok then
      changed=true
      out.changed=out.changed+1
      now=get_now(g) or ""
    end
  end
  out.groups[g]={wanted=wanted,now=now,synced=(ok and now==wanted) and true or false,changed=changed,ssid=ap.ssid or g,subnet=ap.subnet or ""}
end

io.write(jsonc.stringify(out,true),"\n")
