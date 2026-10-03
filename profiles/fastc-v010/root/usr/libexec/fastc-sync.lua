#!/usr/bin/lua

local jsonc=require "luci.jsonc"
local DB="/etc/fastc/nodes.json"
local GROUP_DB="/etc/fastc/groups.json"
local API="http://127.0.0.1:9097"

local function read_json(path,fallback)
  local f=io.open(path,"rb"); if not f then return fallback end
  local raw=f:read("*a") or ""; f:close()
  local ok,obj=pcall(jsonc.parse,raw)
  if ok and type(obj)=="table" then return obj end
  return fallback
end
local function trim(s) return (tostring(s or ""):gsub("^%s+",""):gsub("%s+$","")) end
local function shq(s) return "'"..tostring(s or ""):gsub("'","'\\''").."'" end
local function api_ready()
  return os.execute("curl -fsS --max-time 1 "..shq(API.."/version").." >/dev/null 2>&1")==0
end
local function wait_api()
  for _=1,20 do if api_ready() then return true end os.execute("sleep 0.25") end
  return false
end
local function put_select(group,node)
  local payload=jsonc.stringify({name=node})
  local cmd="curl -fsS --max-time 2 -o /dev/null -X PUT -H 'Content-Type: application/json' --data "..shq(payload).." "..shq(API.."/proxies/FASTC-"..group)
  return os.execute(cmd)==0
end
local function get_now(group)
  local p=io.popen("curl -fsS --max-time 2 "..shq(API.."/proxies/FASTC-"..group).." 2>/dev/null")
  if not p then return nil end
  local raw=p:read("*a") or ""; p:close()
  local ok,obj=pcall(jsonc.parse,raw)
  if ok and type(obj)=="table" then return tostring(obj.now or "") end
  return nil
end

local nodes=read_json(DB,{})
local groups=read_json(GROUP_DB,{})
local members={}
for i=1,20 do members["A"..i]={} end
for _,n in ipairs(nodes) do
  local g=tostring(n.group or "")
  local id=tostring(n.id or "")
  if members[g] and id:match("^n%d+$") then members[g][#members[g]+1]=id end
end

if not wait_api() then
  io.write(jsonc.stringify({ok=false,error="MIHOMO_API_NOT_READY"},true),"\n")
  os.exit(1)
end

local out={ok=true,groups={}}
for i=1,20 do
  local g="A"..i
  local wanted=tostring(groups[g] or "")
  local exists=false
  for _,id in ipairs(members[g]) do if id==wanted then exists=true break end end
  if not exists then wanted=(members[g][1] or "REJECT") end
  local ok=put_select(g,wanted)
  os.execute("sleep 0.03")
  local now=get_now(g) or ""
  out.groups[g]={wanted=wanted,now=now,synced=(ok and now==wanted) and true or false}
end

io.write(jsonc.stringify(out,true),"\n")
