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
local function shq(s) return "'"..tostring(s or ""):gsub("'","'\\''").."'" end
local function run_hot(args)
    local sys=require "luci.sys"; local jsonc=require "luci.jsonc"
    local raw=sys.exec("lua /usr/libexec/fastc-hotctl.lua "..args.." 2>/tmp/fastc-v020-hot.err") or ""
    local ok,obj=pcall(jsonc.parse,raw)
    if ok and type(obj)=="table" then return obj end
    return {ok=false,error="HOTCTL_INVALID_RESPONSE",detail=raw}
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
    local http=require "luci.http"; local uci=require("uci").cursor()
    local action=http.formvalue("action") or "status"
    if action=="status" then write_json(status()); return end

    if action=="bind" then
        local id=http.formvalue("id") or ""; local group=http.formvalue("group") or ""
        if not id:match("^n%d+$") or not group:match("^A%d+$") then write_json({ok=false,error="BAD_BIND_REQUEST"}); return end
        local r=run_hot("bind "..shq(id).." "..shq(group)); write_json(r); return
    end
    if action=="unbind" then
        local id=http.formvalue("id") or ""
        if not id:match("^n%d+$") then write_json({ok=false,error="BAD_NODE"}); return end
        local r=run_hot("unbind "..shq(id)); write_json(r); return
    end
    if action=="chain" then
        local id=http.formvalue("id") or ""; local via=http.formvalue("via") or ""
        if not id:match("^n%d+$") or (via~="" and not via:match("^n%d+$")) then write_json({ok=false,error="BAD_CHAIN_REQUEST"}); return end
        local r=run_hot("chain "..shq(id).." "..shq(via=="" and "-" or via)); write_json(r); return
    end
    if action=="panel" then
        local value=http.formvalue("value") or "collapsed"
        if value~="collapsed" and value~="expanded" then write_json({ok=false,error="BAD_PANEL_VALUE"}); return end
        uci:set("fastc","main","ui_exit_panel",value); uci:commit("fastc")
        write_json({ok=true,value=value}); return
    end
    write_json({ok=false,error="BAD_ACTION"})
end
