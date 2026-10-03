module("luci.controller.fastc_v020", package.seeall)

function index()
    local e=entry({"admin","services","fastc_v020_api"},call("handle"),nil)
    e.leaf=true; e.dependent=false; e.acl_depends={"fastc"}
end

local function write_json(t)
    local http=require "luci.http"
    http.prepare_content("application/json")
    http.write(require("luci.jsonc").stringify(t))
end
local function read_json(path,fallback)
    local f=io.open(path,"rb"); if not f then return fallback end
    local raw=f:read("*a") or ""; f:close()
    local ok,obj=pcall(require("luci.jsonc").parse,raw)
    if ok and type(obj)=="table" then return obj end
    return fallback
end
local function write_json_file(path,obj)
    local jsonc=require "luci.jsonc"
    local tmp=path..".tmp."..tostring(os.time())
    local f=io.open(tmp,"wb"); if not f then return false end
    f:write(jsonc.stringify(obj,true)); f:write("\n"); f:close()
    local ok=os.rename(tmp,path); if not ok then os.remove(tmp); return false end
    return true
end
local function write_file(path,data,mode)
    local f=io.open(path,mode or "wb"); if not f then return false end
    f:write(data or ""); f:close(); return true
end
local function shq(s) return "'"..tostring(s or ""):gsub("'","'\\''").."'" end
local function run_json_cmd(cmd,errfile)
    local sys=require "luci.sys"; local jsonc=require "luci.jsonc"
    local raw=sys.exec(cmd.." 2>"..shq(errfile or "/tmp/fastc-v020.err")) or ""
    local ok,obj=pcall(jsonc.parse,raw)
    if ok and type(obj)=="table" then return obj end
    return {ok=false,error="INVALID_RESPONSE",detail=raw}
end
local function run_hot(args)
    return run_json_cmd("lua /usr/libexec/fastc-hotctl.lua "..args,"/tmp/fastc-v020-hot.err")
end
local function hot_reload()
    return run_json_cmd("lua /usr/libexec/fastc-reload.lua","/tmp/fastc-v020-reload.err")
end
local function status()
    local uci=require("uci").cursor(); local sys=require "luci.sys"
    local nodes=read_json("/etc/fastc/nodes.json",{})
    local bindings=read_json("/etc/fastc/bindings.json",{})
    local chains=read_json("/etc/fastc/chains.json",{})
    local topology=read_json("/etc/fastc/topology.json",{aps={}})
    local mode=uci:get("fastc","main","mode") or "fastacl"
    local version=uci:get("fastc","main","version") or "0.2.0-dev"
    local panel=uci:get("fastc","main","ui_exit_panel") or "collapsed"
    local mihomo=sys.call("pidof mihomo >/dev/null 2>&1")==0
    local api=sys.call("curl -fsS --connect-timeout 1 --max-time 1 http://127.0.0.1:9097/version >/dev/null 2>&1")==0
    return {ok=true,nodes=nodes,bindings=bindings,chains=chains,topology=topology,mode=mode,version=version,ui_exit_panel=panel,mihomo=mihomo,api=api,node_count=#nodes}
end

function handle()
    local http=require "luci.http"; local uci=require("uci").cursor(); local sys=require "luci.sys"; local jsonc=require "luci.jsonc"
    local action=http.formvalue("action") or "status"
    if action=="status" then write_json(status()); return end

    if action=="bind" then
        local id=http.formvalue("id") or ""; local group=http.formvalue("group") or ""
        if not id:match("^n%d+$") or not group:match("^A%d+$") then write_json({ok=false,error="BAD_BIND_REQUEST"}); return end
        write_json(run_hot("bind "..shq(id).." "..shq(group))); return
    end
    if action=="unbind" then
        local id=http.formvalue("id") or ""
        if not id:match("^n%d+$") then write_json({ok=false,error="BAD_NODE"}); return end
        write_json(run_hot("unbind "..shq(id))); return
    end
    if action=="chain" then
        local id=http.formvalue("id") or ""; local via=http.formvalue("via") or ""
        if not id:match("^n%d+$") or (via~="" and not via:match("^n%d+$")) then write_json({ok=false,error="BAD_CHAIN_REQUEST"}); return end
        write_json(run_hot("chain "..shq(id).." "..shq(via=="" and "-" or via))); return
    end
    if action=="panel" then
        local value=http.formvalue("value") or "collapsed"
        if value~="collapsed" and value~="expanded" then write_json({ok=false,error="BAD_PANEL_VALUE"}); return end
        uci:set("fastc","main","ui_exit_panel",value); uci:commit("fastc")
        write_json({ok=true,value=value}); return
    end

    if action=="import" then
        local chunk=http.formvalue("chunk") or ""; local idx=tonumber(http.formvalue("chunk_index") or ""); local total=tonumber(http.formvalue("total_chunks") or "")
        if not idx or not total or idx<0 or total<1 or total>128 or idx>=total then write_json({ok=false,error="BAD_IMPORT_CHUNK"}); return end
        if #chunk>65536 then write_json({ok=false,error="CHUNK_TOO_LARGE"}); return end
        local tmp="/tmp/fastc-v020-import.links"
        if not write_file(tmp,chunk,(idx==0) and "wb" or "ab") then write_json({ok=false,error="IMPORT_OPEN_FAILED"}); return end
        if idx+1<total then write_json({ok=true,finished=false,chunk=idx+1,total=total}); return end
        local raw=sys.exec("lua /usr/libexec/fastc-import.lua "..shq(tmp).." 2>/tmp/fastc-v020-import.err") or ""
        local ok,res=pcall(jsonc.parse,raw)
        if not ok or type(res)~="table" or res.ok~=true then write_json({ok=false,error="IMPORT_FAILED",detail=raw}); return end
        sys.call("lua /usr/libexec/fastc-state.lua migrate >/tmp/fastc-v020-migrate.json 2>/tmp/fastc-v020-migrate.err")
        local rr=hot_reload()
        res.finished=true; res.hot_reload=rr; res.restarted=false
        write_json(res); return
    end

    if action=="delete" then
        local id=http.formvalue("id") or ""
        if not id:match("^n%d+$") then write_json({ok=false,error="BAD_NODE"}); return end
        local nodes=read_json("/etc/fastc/nodes.json",{}); local found=false; local out={}
        for _,n in ipairs(nodes) do if tostring(n.id or "")==id then found=true else out[#out+1]=n end end
        if not found then write_json({ok=false,error="NODE_NOT_FOUND"}); return end
        run_hot("unbind "..shq(id))
        local chains=read_json("/etc/fastc/chains.json",{})
        chains[id]=nil
        for nid,c in pairs(chains) do local via=type(c)=="table" and tostring(c.via or "") or tostring(c or ""); if via==id then chains[nid]=nil end end
        if not write_json_file("/etc/fastc/chains.json",chains) or not write_json_file("/etc/fastc/nodes.json",out) then write_json({ok=false,error="DELETE_WRITE_FAILED"}); return end
        sys.call("lua /usr/libexec/fastc-state.lua migrate >/tmp/fastc-v020-delete-migrate.json 2>/tmp/fastc-v020-delete-migrate.err")
        local rr=hot_reload()
        write_json({ok=true,id=id,total=#out,hot_reload=rr,restarted=false}); return
    end

    write_json({ok=false,error="BAD_ACTION"})
end
