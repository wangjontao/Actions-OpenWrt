#!/usr/bin/lua

local jsonc=require "luci.jsonc"
local API="http://127.0.0.1:9097"
local BIND_DB="/etc/fastc/bindings.json"
local LAST_BIND="/etc/fastc/last-good-bindings.json"
local CHAIN_DB="/etc/fastc/chains.json"
local LAST_CHAIN="/etc/fastc/last-good-chains.json"
local CONFIG="/etc/fastc/config.yaml"

local function shq(s) return "'"..tostring(s or ""):gsub("'","'\\''").."'" end
local function trim(s) return (tostring(s or ""):gsub("^%s+",""):gsub("%s+$","")) end
local function read_json(path,fallback)
  local f=io.open(path,"rb"); if not f then return fallback end
  local raw=f:read("*a") or ""; f:close(); local ok,obj=pcall(jsonc.parse,raw)
  if ok and type(obj)=="table" then return obj end; return fallback
end
local function copy_file(src,dst)
  local f=io.open(src,"rb"); if not f then return false end; local data=f:read("*a") or ""; f:close()
  local w=io.open(dst,"wb"); if not w then return false end; w:write(data); w:close(); return true
end
local function run_json(cmd)
  local p=io.popen(cmd.." 2>/tmp/fastc-hotctl.err"); if not p then return false,nil,"POPEN_FAILED" end
  local raw=p:read("*a") or ""; p:close(); local ok,obj=pcall(jsonc.parse,raw)
  if ok and type(obj)=="table" then return obj.ok==true,obj,raw end; return false,nil,raw
end
local function api_ready() return os.execute("curl -fsS --connect-timeout 1 --max-time 1 "..shq(API.."/version").." >/dev/null 2>&1")==0 end
local function api_select_name(name,node)
  local payload=jsonc.stringify({name=node})
  local cmd="curl -fsS --connect-timeout 1 --max-time 3 -o /tmp/fastc-hot-select.body -w '%{http_code}' -X PUT -H 'Content-Type: application/json' --data "..shq(payload).." "..shq(API.."/proxies/"..name).." 2>/tmp/fastc-hot-select.err"
  local p=io.popen(cmd); if not p then return false,"POPEN_FAILED" end
  local code=trim(p:read("*a") or ""); p:close(); if code=="204" or code=="200" then return true end
  local f=io.open("/tmp/fastc-hot-select.body","rb"); local body=f and (f:read("*a") or "") or ""; if f then f:close() end
  return false,"HTTP_"..code..":"..trim(body)
end
local function api_select(group,node) return api_select_name("FASTC-"..group,node) end
local function reload_config()
  local payload=jsonc.stringify({path=CONFIG})
  local cmd="curl -fsS --connect-timeout 1 --max-time 6 -o /tmp/fastc-hot-reload.body -w '%{http_code}' -X PUT -H 'Content-Type: application/json' --data "..shq(payload).." "..shq(API.."/configs?force=true").." 2>/tmp/fastc-hot-reload.err"
  local p=io.popen(cmd); if not p then return false,"POPEN_FAILED" end
  local code=trim(p:read("*a") or ""); p:close(); if code=="204" or code=="200" then return true end
  local f=io.open("/tmp/fastc-hot-reload.body","rb"); local body=f and (f:read("*a") or "") or ""; if f then f:close() end
  return false,"HTTP_"..code..":"..trim(body)
end
local function generate_validate()
  local p=io.popen("lua /usr/libexec/fastc-generate.lua 2>/tmp/fastc-hot-generate.err")
  local raw=p and (p:read("*a") or "") or ""; if p then p:close() end
  local ok,obj=pcall(jsonc.parse,raw)
  if not ok or type(obj)~="table" or obj.ok~=true then return false,"GENERATE_FAILED:"..raw end
  local rc=os.execute("/usr/bin/mihomo -t -d /etc/fastc -f "..shq(CONFIG).." >/tmp/fastc-hotcheck.log 2>&1")
  if rc~=0 then local f=io.open("/tmp/fastc-hotcheck.log","rb"); local d=f and (f:read("*a") or "") or ""; if f then f:close() end; return false,"CONFIG_INVALID:"..trim(d) end
  return true,obj
end
local function binding_node(bindings,group)
  local b=bindings[group]; if type(b)=="table" then return tostring(b.node or "") end; return tostring(b or "")
end
local function restore_bindings(old,groups)
  if not copy_file(LAST_BIND,BIND_DB) then return false end
  os.execute("lua /usr/libexec/fastc-state.lua migrate >/tmp/fastc-hot-restore-bind.json 2>/tmp/fastc-hot-restore-bind.err")
  if api_ready() then for _,g in ipairs(groups or {}) do local id=binding_node(old,g); if id=="" then id="REJECT" end; api_select(g,id) end end
  return true
end
local function old_chain_target(old,node)
  local c=old[node]; local via=type(c)=="table" and tostring(c.via or "") or tostring(c or ""); return via~="" and via or "DIRECT"
end
local function restore_chain(old,node)
  if not copy_file(LAST_CHAIN,CHAIN_DB) then return false end
  os.execute("lua /usr/libexec/fastc-state.lua migrate >/tmp/fastc-hot-restore-chain.json 2>/tmp/fastc-hot-restore-chain.err")
  if api_ready() then api_select_name("FASTC-CHAIN-"..node,old_chain_target(old,node)) end
  return true
end

local function bind(node,group)
  local old=read_json(BIND_DB,{})
  local ok,obj,raw=run_json("lua /usr/libexec/fastc-state.lua bind "..shq(node).." "..shq(group)); if not ok then return false,(obj and obj.error) or raw end
  local r=obj.result or {}; local affected={group}; if r.moved_from and r.moved_from~="" and r.moved_from~=group then affected[#affected+1]=r.moved_from end
  if not api_ready() then return true,{hot=false,offline=true,state=r} end
  local s,e=api_select(group,node); if s and r.moved_from and r.moved_from~="" and r.moved_from~=group then s,e=api_select(r.moved_from,"REJECT") end
  if not s then restore_bindings(old,affected); return false,"SELECTOR_APPLY_FAILED:"..tostring(e or "") end
  return true,{hot=true,restarted=false,state=r}
end
local function unbind(node)
  local old=read_json(BIND_DB,{})
  local ok,obj,raw=run_json("lua /usr/libexec/fastc-state.lua unbind "..shq(node)); if not ok then return false,(obj and obj.error) or raw end
  local r=obj.result or {}; local affected=r.removed or {}; if not api_ready() then return true,{hot=false,offline=true,state=r} end
  for _,g in ipairs(affected) do local s,e=api_select(g,"REJECT"); if not s then restore_bindings(old,affected); return false,"SELECTOR_APPLY_FAILED:"..tostring(e or "") end end
  return true,{hot=true,restarted=false,state=r}
end
local function chain(node,via)
  local old=read_json(CHAIN_DB,{})
  local ok,obj,raw=run_json("lua /usr/libexec/fastc-state.lua chain "..shq(node).." "..shq(via=="" and "-" or via)); if not ok then return false,(obj and obj.error) or raw end
  local r=obj.result or {}; local target=via~="" and via or "DIRECT"
  if not api_ready() then return true,{hot=false,offline=true,state=r} end
  local s,e=api_select_name("FASTC-CHAIN-"..node,target)
  if s then return true,{hot=true,restarted=false,reloaded=false,state=r} end

  -- First use of a new relay may not yet exist in this node's bounded chain
  -- selector. Register it by one in-process hot reload, never by restarting mihomo.
  local gv,gobj=generate_validate()
  if not gv then restore_chain(old,node); return false,tostring(gobj) end
  local rr,re=reload_config()
  if not rr then restore_chain(old,node); return false,"RELAY_REGISTER_RELOAD_FAILED:"..tostring(re or "") end
  s,e=api_select_name("FASTC-CHAIN-"..node,target)
  if not s then restore_chain(old,node); local ov=generate_validate(); if ov then reload_config() end; return false,"CHAIN_SELECT_FAILED:"..tostring(e or "") end
  return true,{hot=true,restarted=false,reloaded=true,state=r}
end

local cmd=tostring(arg[1] or "status"); local ok,res
if cmd=="bind" then ok,res=bind(tostring(arg[2] or ""),tostring(arg[3] or ""))
elseif cmd=="unbind" then ok,res=unbind(tostring(arg[2] or ""))
elseif cmd=="chain" then local via=tostring(arg[3] or ""); if via=="-" then via="" end; ok,res=chain(tostring(arg[2] or ""),via)
elseif cmd=="status" then ok=true; res={bindings=read_json(BIND_DB,{}),chains=read_json(CHAIN_DB,{}),api=api_ready()}
else ok=false; res="BAD_COMMAND:"..cmd end
if ok then io.write(jsonc.stringify({ok=true,result=res},true),"\n"); os.exit(0) end
io.write(jsonc.stringify({ok=false,error=tostring(res or "UNKNOWN")},true),"\n"); os.exit(1)
