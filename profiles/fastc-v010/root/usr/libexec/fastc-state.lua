#!/usr/bin/lua

local jsonc=require "luci.jsonc"

local NODE_DB="/etc/fastc/nodes.json"
local BIND_DB="/etc/fastc/bindings.json"
local CHAIN_DB="/etc/fastc/chains.json"
local TOPO_DB="/etc/fastc/topology.json"
local LAST_BIND="/etc/fastc/last-good-bindings.json"
local LAST_CHAIN="/etc/fastc/last-good-chains.json"

local function read_json(path,fallback)
  local f=io.open(path,"rb")
  if not f then return fallback end
  local raw=f:read("*a") or ""; f:close()
  local ok,obj=pcall(jsonc.parse,raw)
  if ok and type(obj)=="table" then return obj end
  return fallback
end

local function atomic_write(path,obj)
  local pid=tostring((require("nixio").getpid and require("nixio").getpid()) or os.time())
  local tmp=path..".tmp."..pid
  local f=io.open(tmp,"wb")
  if not f then return false,"OPEN_FAILED:"..tmp end
  f:write(jsonc.stringify(obj,true)); f:write("\n"); f:close()
  local ok,err=os.rename(tmp,path)
  if not ok then os.remove(tmp); return false,"RENAME_FAILED:"..tostring(err or "") end
  return true
end

local function clone(obj)
  local ok,v=pcall(jsonc.parse,jsonc.stringify(obj or {}))
  return (ok and type(v)=="table") and v or {}
end

local function node_map(nodes)
  local m={}
  for _,n in ipairs(nodes or {}) do
    local id=tostring(n.id or "")
    if id:match("^n%d+$") then m[id]=n end
  end
  return m
end

local function topo_map(topo)
  local m={}
  for _,ap in ipairs((topo and topo.aps) or {}) do
    local g=tostring(ap.group or ("A"..tostring(ap.slot or "")))
    if g:match("^A%d+$") then
      m[g]={ssid=tostring(ap.ssid or g),subnet=tostring(ap.subnet or ""),network=tostring(ap.network or "")}
    end
  end
  return m
end

local function sync_node_display(nodes,bindings,chains)
  for _,n in ipairs(nodes) do n.group=nil; n.chain=nil end
  local nm=node_map(nodes)
  for g,b in pairs(bindings or {}) do
    local id=type(b)=="table" and tostring(b.node or "") or tostring(b or "")
    if nm[id] then nm[id].group=g end
  end
  for id,c in pairs(chains or {}) do
    local via=type(c)=="table" and tostring(c.via or "") or tostring(c or "")
    if nm[id] and via~="" then nm[id].chain=via end
  end
end

local function validate_chains(nodes,chains)
  local nm=node_map(nodes)
  for id,c in pairs(chains or {}) do
    local via=type(c)=="table" and tostring(c.via or "") or tostring(c or "")
    if not nm[id] then return false,"CHAIN_NODE_NOT_FOUND:"..id end
    if via~="" and not nm[via] then return false,"CHAIN_VIA_NOT_FOUND:"..via end
    if via~="" and via==id then return false,"CHAIN_SELF:"..id end
  end
  for start,_ in pairs(chains or {}) do
    local seen={}; local cur=start
    while cur and cur~="" do
      if seen[cur] then return false,"CHAIN_LOOP:"..start..":"..cur end
      seen[cur]=true
      local c=chains[cur]
      if not c then break end
      local via=type(c)=="table" and tostring(c.via or "") or tostring(c or "")
      if via=="" then break end
      cur=via
    end
  end
  return true
end

local function save_all(nodes,bindings,chains)
  sync_node_display(nodes,bindings,chains)
  local ok,err=atomic_write(BIND_DB,bindings); if not ok then return false,err end
  ok,err=atomic_write(CHAIN_DB,chains); if not ok then return false,err end
  ok,err=atomic_write(NODE_DB,nodes); if not ok then return false,err end
  return true
end

local function migrate()
  local nodes=read_json(NODE_DB,{})
  local topo=read_json(TOPO_DB,{aps={}})
  local tm=topo_map(topo)
  local bindings=read_json(BIND_DB,{})
  local chains=read_json(CHAIN_DB,{})
  local bind_empty=(next(bindings)==nil)
  local chain_empty=(next(chains)==nil)

  if bind_empty then
    for _,n in ipairs(nodes) do
      local id=tostring(n.id or ""); local g=tostring(n.group or "")
      if id:match("^n%d+$") and tm[g] and not bindings[g] then
        bindings[g]={node=id,ssid=tm[g].ssid,subnet=tm[g].subnet,network=tm[g].network}
      end
    end
  end
  if chain_empty then
    for _,n in ipairs(nodes) do
      local id=tostring(n.id or ""); local via=tostring(n.chain or "")
      if id:match("^n%d+$") and via:match("^n%d+$") and id~=via then chains[id]={via=via} end
    end
  end

  local ok,err=validate_chains(nodes,chains)
  if not ok then return false,err end
  ok,err=save_all(nodes,bindings,chains); if not ok then return false,err end
  atomic_write(LAST_BIND,bindings); atomic_write(LAST_CHAIN,chains)
  return true,{bindings=bindings,chains=chains,nodes=#nodes}
end

local function bind(node,group)
  local nodes=read_json(NODE_DB,{})
  local nm=node_map(nodes)
  local topo=read_json(TOPO_DB,{aps={}}); local tm=topo_map(topo)
  local bindings=read_json(BIND_DB,{})
  local chains=read_json(CHAIN_DB,{})
  if node~="DIRECT" and node~="REJECT" and not nm[node] then return false,"NODE_NOT_FOUND:"..node end
  if not tm[group] then return false,"GROUP_NOT_FOUND:"..group end

  local old=clone(bindings)
  local moved_from=nil
  for g,b in pairs(bindings) do
    local id=type(b)=="table" and tostring(b.node or "") or tostring(b or "")
    if node~="DIRECT" and node~="REJECT" and id==node and g~=group then bindings[g]=nil; moved_from=g end
  end
  local released=nil
  if bindings[group] then
    released=type(bindings[group])=="table" and tostring(bindings[group].node or "") or tostring(bindings[group] or "")
    if released==node then released=nil end
  end
  bindings[group]={node=node,ssid=tm[group].ssid,subnet=tm[group].subnet,network=tm[group].network}

  atomic_write(LAST_BIND,old)
  local ok,err=save_all(nodes,bindings,chains)
  if not ok then return false,err end
  return true,{group=group,node=node,released=released,moved_from=moved_from,bindings=bindings}
end

local function unbind(node)
  local nodes=read_json(NODE_DB,{})
  local nm=node_map(nodes)
  local bindings=read_json(BIND_DB,{})
  local chains=read_json(CHAIN_DB,{})
  if not nm[node] then return false,"NODE_NOT_FOUND:"..node end
  local old=clone(bindings); local removed={}
  for g,b in pairs(bindings) do
    local id=type(b)=="table" and tostring(b.node or "") or tostring(b or "")
    if id==node then bindings[g]=nil; removed[#removed+1]=g end
  end
  atomic_write(LAST_BIND,old)
  local ok,err=save_all(nodes,bindings,chains)
  if not ok then return false,err end
  return true,{node=node,removed=removed}
end

local function set_chain(node,via)
  local nodes=read_json(NODE_DB,{})
  local nm=node_map(nodes)
  local bindings=read_json(BIND_DB,{})
  local chains=read_json(CHAIN_DB,{})
  if not nm[node] then return false,"NODE_NOT_FOUND:"..node end
  if via~="" and not nm[via] then return false,"CHAIN_VIA_NOT_FOUND:"..via end
  if via==node then return false,"CHAIN_SELF:"..node end
  local old=clone(chains)
  if via=="" then chains[node]=nil else chains[node]={via=via} end
  local ok,err=validate_chains(nodes,chains)
  if not ok then return false,err end
  atomic_write(LAST_CHAIN,old)
  ok,err=save_all(nodes,bindings,chains)
  if not ok then return false,err end
  return true,{node=node,via=via,chains=chains}
end

local function status()
  local nodes=read_json(NODE_DB,{})
  local bindings=read_json(BIND_DB,{})
  local chains=read_json(CHAIN_DB,{})
  local ok,err=validate_chains(nodes,chains)
  return true,{nodes=#nodes,bindings=bindings,chains=chains,chains_valid=ok,chain_error=err}
end

local cmd=arg[1] or "status"
local ok,res
if cmd=="migrate" then ok,res=migrate()
elseif cmd=="bind" then ok,res=bind(tostring(arg[2] or ""),tostring(arg[3] or ""))
elseif cmd=="unbind" then ok,res=unbind(tostring(arg[2] or ""))
elseif cmd=="chain" then local via=tostring(arg[3] or ""); if via=="-" then via="" end; ok,res=set_chain(tostring(arg[2] or ""),via)
elseif cmd=="status" then ok,res=status()
else ok=false; res="BAD_COMMAND:"..cmd end

if ok then io.write(jsonc.stringify({ok=true,result=res},true),"\n"); os.exit(0) end
io.write(jsonc.stringify({ok=false,error=tostring(res or "UNKNOWN")},true),"\n"); os.exit(1)
