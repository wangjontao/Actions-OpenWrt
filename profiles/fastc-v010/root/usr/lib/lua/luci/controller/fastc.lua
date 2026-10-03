module("luci.controller.fastc", package.seeall)

function index()
    local page=entry({"admin","services","fastc"},template("fastc/console"),_("FastC"),27)
    page.leaf=true; page.dependent=false; page.acl_depends={"fastc"}
    local api=entry({"admin","services","fastc_api"},call("handle"),nil)
    api.leaf=true; api.dependent=false; api.acl_depends={"fastc"}
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
    local f=io.open(path,"wb"); if not f then return false end
    f:write(require("luci.jsonc").stringify(obj,true)); f:close(); return true
end
local function write_file(path,data,mode)
    local f=io.open(path,mode or "wb"); if not f then return false end
    f:write(data or ""); f:close(); return true
end
local function shell_quote(s) return "'"..tostring(s or ""):gsub("'","'\\''").."'" end
local function trim(s) return (tostring(s or ""):gsub("^%s+",""):gsub("%s+$","")) end

local function core_info()
    local sys=require "luci.sys"; local fs=require "nixio.fs"
    local path=trim(sys.exec("command -v mihomo 2>/dev/null") or "")
    if path=="" then path=trim(sys.exec("command -v clash 2>/dev/null") or "") end
    if path=="" and fs.access("/etc/openclash/core/clash_meta","x") then path="/etc/openclash/core/clash_meta" end
    if path=="" and fs.access("/etc/openclash/core/clash","x") then path="/etc/openclash/core/clash" end
    if path=="" and fs.access("/usr/bin/clash_meta","x") then path="/usr/bin/clash_meta" end
    local any_running=sys.call("pidof mihomo clash clash_meta >/dev/null 2>&1 || pgrep -f '/etc/openclash/core/clash_meta' >/dev/null 2>&1")==0
    local fastc_running=sys.call("/etc/init.d/fastc running >/dev/null 2>&1")==0
    local version=path~="" and trim(sys.exec(shell_quote(path).." -v 2>/dev/null | head -n1") or "") or ""
    return {present=path~="",path=path,running=any_running,fastc_running=fastc_running,version=version}
end
local function fastacl_info(uci)
    local sys=require "luci.sys"
    local enabled=uci:get("juliang_fastacl","main","enabled")=="1"
    local guardian=sys.call("pgrep -f '/usr/bin/juliang-fastacl-guard' >/dev/null 2>&1")==0
    local table_ok=sys.call("nft list table inet juliang_fastacl >/dev/null 2>&1")==0
    return {installed=sys.call("test -x /usr/bin/juliang-fastacl")==0,enabled=enabled,running=guardian or table_ok}
end
local function fastc_config(uci)
    return {
        version=uci:get("fastc","main","version") or "0.1.4-dev",
        enabled=uci:get("fastc","main","enabled")=="1",
        mode=uci:get("fastc","main","mode") or "fastacl",
        core=uci:get("fastc","main","core") or "mihomo",
        core_path=uci:get("fastc","main","core_path") or "/usr/bin/mihomo",
        core_version=uci:get("fastc","main","core_version") or "",
        controller=uci:get("fastc","main","controller") or "127.0.0.1:9097",
        tproxy_port=tonumber(uci:get("fastc","main","tproxy_port") or "7895") or 7895,
        dns_port=tonumber(uci:get("fastc","main","dns_port") or "1053") or 1053
    }
end
local function dataplane_info()
    local sys=require "luci.sys"
    return {
        tproxy=sys.call("nft list table inet fastc_tproxy >/dev/null 2>&1")==0,
        killswitch=sys.call("nft list table inet fastc_killswitch >/dev/null 2>&1")==0,
        route=sys.call("ip rule show 2>/dev/null | grep -q 'lookup 101'")==0
    }
end
local function generate_config()
    local sys=require "luci.sys"; local jsonc=require "luci.jsonc"
    local raw=sys.exec("lua /usr/libexec/fastc-generate.lua 2>/tmp/fastc-generate.log") or ""
    local ok,obj=pcall(jsonc.parse,raw)
    if not ok or type(obj)~="table" or obj.ok~=true then return nil,(sys.exec("cat /tmp/fastc-generate.log 2>/dev/null") or raw) end
    return obj
end
local function restart_manager()
    local sys=require "luci.sys"
    local gen,err=generate_config(); if not gen then return nil,err end
    if sys.call("/etc/init.d/fastc running >/dev/null 2>&1")==0 then
        if sys.call("/etc/init.d/fastc restart >/tmp/fastc-restart.log 2>&1")~=0 then return nil,sys.exec("cat /tmp/fastc-restart.log 2>/dev/null") end
        sys.call("sleep 1")
    end
    return gen
end
local function ensure_manager()
    local sys=require "luci.sys"; local c=core_info()
    if not c.present then return false,"MIHOMO_CORE_MISSING" end
    local gen,err=generate_config(); if not gen then return false,err end
    if c.fastc_running then return true,gen end
    if sys.call("/etc/init.d/fastc start >/tmp/fastc-start.log 2>&1")~=0 then return false,sys.exec("cat /tmp/fastc-start.log /tmp/fastc-mihomo-check.log 2>/dev/null") end
    sys.call("sleep 1")
    if sys.call("/etc/init.d/fastc running >/dev/null 2>&1")~=0 then return false,sys.exec("cat /tmp/fastc-start.log /tmp/fastc-mihomo-check.log 2>/dev/null") end
    return true,gen
end
local function valid_group(group)
    if group=="" then return true end
    local n=tonumber(tostring(group):match("^A(%d+)$") or "")
    return n and n>=1 and n<=20
end
local function find_node(nodes,id)
    for _,n in ipairs(nodes) do if tostring(n.id)==tostring(id) then return n end end
    return nil
end

function handle()
    local http=require "luci.http"; local sys=require "luci.sys"; local jsonc=require "luci.jsonc"; local fs=require "nixio.fs"; local uci=require("uci").cursor()
    local action=http.formvalue("action") or "status"

    if action=="status" then
        local nodes=read_json("/etc/fastc/nodes.json",{})
        local groups=read_json("/etc/fastc/groups.json",{})
        local core=core_info()
        write_json({ok=true,config=fastc_config(uci),core_present=core.present,core_path=core.path,core_running=core.running,fastc_running=core.fastc_running,core_version=core.version,fastacl=fastacl_info(uci),dataplane=dataplane_info(),nodes=nodes,groups=groups,node_count=#nodes})
        return
    end

    if action=="install_core" then
        if (uci:get("fastc","main","mode") or "fastacl")=="fastc" then write_json({ok=false,error="SWITCH_TO_FASTACL_FIRST"}); return end
        if not fs.access("/usr/bin/fastc-core","x") then write_json({ok=false,error="CORE_MANAGER_MISSING"}); return end
        local raw=sys.exec("/usr/bin/fastc-core install 2>&1") or ""; local core=core_info()
        if not core.present then write_json({ok=false,error="CORE_INSTALL_FAILED",detail=raw}); return end
        write_json({ok=true,core_present=true,core_path=core.path,core_running=core.running,core_version=core.version,detail=raw}); return
    end

    if action=="start_manager" then
        local ok,detail=ensure_manager(); if not ok then write_json({ok=false,error="FASTC_MANAGER_START_FAILED",detail=detail}); return end
        write_json({ok=true,fastc_running=true,generated=detail}); return
    end
    if action=="stop_manager" then
        if (uci:get("fastc","main","mode") or "fastacl")=="fastc" then write_json({ok=false,error="FASTC_TRAFFIC_MODE_ACTIVE"}); return end
        sys.call("/etc/init.d/fastc stop >/dev/null 2>&1"); write_json({ok=true,fastc_running=false}); return
    end

    if action=="switch_mode" then
        local target=http.formvalue("target") or ""
        if target~="fastc" and target~="fastacl" then write_json({ok=false,error="BAD_MODE"}); return end
        if not fs.access("/usr/bin/fastc-mode","x") then write_json({ok=false,error="MODE_HELPER_MISSING"}); return end
        local raw=sys.exec("/usr/bin/fastc-mode "..shell_quote(target).." 2>&1") or ""
        local now=uci:get("fastc","main","mode") or "fastacl"
        if now~=target then write_json({ok=false,error="MODE_SWITCH_FAILED",detail=raw,current=now}); return end
        write_json({ok=true,mode=now,detail=raw}); return
    end

    if action=="assign" then
        local id=http.formvalue("id") or ""; local group=http.formvalue("group") or ""
        if not id:match("^n%d+$") then write_json({ok=false,error="BAD_NODE"}); return end
        if not valid_group(group) then write_json({ok=false,error="BAD_GROUP"}); return end
        local nodes=read_json("/etc/fastc/nodes.json",{}); local n=find_node(nodes,id)
        if not n then write_json({ok=false,error="NODE_NOT_FOUND"}); return end
        local old=n.group; n.group=(group~="" and group or nil)
        if not write_json_file("/etc/fastc/nodes.json",nodes) then write_json({ok=false,error="WRITE_FAILED"}); return end
        local gen,err=restart_manager()
        if not gen then n.group=old; write_json_file("/etc/fastc/nodes.json",nodes); restart_manager(); write_json({ok=false,error="GENERATE_FAILED",detail=err}); return end
        local groups=read_json("/etc/fastc/groups.json",{})
        if old and groups[old]==id then groups[old]=nil; write_json_file("/etc/fastc/groups.json",groups) end
        write_json({ok=true,id=id,group=group,generated=gen}); return
    end

    if action=="set_chain" then
        local id=http.formvalue("id") or ""; local chain=http.formvalue("chain") or ""
        if not id:match("^n%d+$") then write_json({ok=false,error="BAD_NODE"}); return end
        if chain~="" and not chain:match("^n%d+$") then write_json({ok=false,error="BAD_CHAIN"}); return end
        if chain==id then write_json({ok=false,error="CHAIN_SELF"}); return end
        local nodes=read_json("/etc/fastc/nodes.json",{}); local n=find_node(nodes,id)
        if not n then write_json({ok=false,error="NODE_NOT_FOUND"}); return end
        if chain~="" and not find_node(nodes,chain) then write_json({ok=false,error="CHAIN_NODE_NOT_FOUND"}); return end
        local old=n.chain; n.chain=(chain~="" and chain or nil); n.last_check=nil; n.last_delay=nil; n.last_ok=nil; n.last_error=nil
        write_json_file("/etc/fastc/nodes.json",nodes)
        local gen,err=restart_manager()
        if not gen then n.chain=old; write_json_file("/etc/fastc/nodes.json",nodes); restart_manager(); write_json({ok=false,error="CHAIN_GENERATE_FAILED",detail=err}); return end
        write_json({ok=true,id=id,chain=chain,generated=gen}); return
    end

    if action=="select_group" then
        local group=http.formvalue("group") or ""; local id=http.formvalue("id") or ""
        if not valid_group(group) or group=="" then write_json({ok=false,error="BAD_GROUP"}); return end
        local nodes=read_json("/etc/fastc/nodes.json",{})
        if id~="" then local n=find_node(nodes,id); if not n or n.group~=group then write_json({ok=false,error="NODE_NOT_IN_GROUP"}); return end end
        local groups=read_json("/etc/fastc/groups.json",{}); local old=groups[group]; groups[group]=(id~="" and id or nil)
        if not write_json_file("/etc/fastc/groups.json",groups) then write_json({ok=false,error="WRITE_FAILED"}); return end
        local gen,err=restart_manager()
        if not gen then groups[group]=old; write_json_file("/etc/fastc/groups.json",groups); restart_manager(); write_json({ok=false,error="GROUP_RELOAD_FAILED",detail=err}); return end
        write_json({ok=true,group=group,id=id}); return
    end

    if action=="test" then
        local id=http.formvalue("id") or ""; if not id:match("^n%d+$") then write_json({ok=false,error="BAD_NODE"}); return end
        local nodes=read_json("/etc/fastc/nodes.json",{}); local target=find_node(nodes,id); if not target then write_json({ok=false,error="NODE_NOT_FOUND"}); return end
        local okm,gen=ensure_manager(); if not okm then write_json({ok=false,error="FASTC_MANAGER_START_FAILED",detail=gen}); return end
        local supported=false; for _,sid in ipairs(gen.supported or {}) do if sid==id then supported=true; break end end
        if not supported then target.last_ok=false; target.last_error="当前 FastC 运行时不支持该节点或链式配置无效"; target.last_check=os.time(); write_json_file("/etc/fastc/nodes.json",nodes); write_json({ok=false,error="NODE_RUNTIME_UNSUPPORTED",detail=target.last_error}); return end
        local url="http://127.0.0.1:9097/proxies/"..id.."/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=6000&expected=204"
        local raw=sys.exec("curl -sS --max-time 8 "..shell_quote(url).." 2>/tmp/fastc-test-curl.log") or ""
        local pok,obj=pcall(jsonc.parse,raw); local delay=pok and type(obj)=="table" and tonumber(obj.delay or "") or nil
        target.last_check=os.time()
        if delay and delay>0 then target.last_ok=true; target.last_delay=delay; target.last_error=nil; write_json_file("/etc/fastc/nodes.json",nodes); write_json({ok=true,id=id,delay=delay}); return end
        target.last_ok=false; target.last_delay=nil; target.last_error=(raw~="" and raw or trim(sys.exec("cat /tmp/fastc-test-curl.log 2>/dev/null") or "检测失败")); write_json_file("/etc/fastc/nodes.json",nodes); write_json({ok=false,error="NODE_TEST_FAILED",detail=target.last_error,id=id}); return
    end

    if action=="import" then
        local chunk=http.formvalue("chunk") or ""; local chunk_index=tonumber(http.formvalue("chunk_index") or ""); local total_chunks=tonumber(http.formvalue("total_chunks") or "")
        if not chunk_index or not total_chunks or chunk_index<0 or total_chunks<1 or total_chunks>64 or chunk_index>=total_chunks then write_json({ok=false,error="BAD_IMPORT_CHUNK"}); return end
        if #chunk>65536 then write_json({ok=false,error="CHUNK_TOO_LARGE"}); return end
        local tmp="/tmp/fastc-import.links"; if not write_file(tmp,chunk,(chunk_index==0) and "wb" or "ab") then write_json({ok=false,error="IMPORT_OPEN_FAILED"}); return end
        if chunk_index+1<total_chunks then write_json({ok=true,chunk=chunk_index+1,total=total_chunks,finished=false}); return end
        local raw=sys.exec("lua /usr/libexec/fastc-import.lua "..shell_quote(tmp).." 2>/tmp/fastc-import.log") or ""; local ok,result=pcall(jsonc.parse,raw)
        if not ok or type(result)~="table" or result.ok~=true then local detail=sys.exec("cat /tmp/fastc-import.log 2>/dev/null") or ""; if detail=="" then detail=raw end; write_json({ok=false,error="IMPORT_FAILED",detail=detail}); return end
        restart_manager(); result.finished=true; write_json(result); return
    end

    if action=="delete" then
        local id=http.formvalue("id") or ""; if not id:match("^n%d+$") then write_json({ok=false,error="BAD_NODE"}); return end
        local nodes=read_json("/etc/fastc/nodes.json",{}); local out,removed={},false
        for _,n in ipairs(nodes) do
            if tostring(n.id)==id then removed=true else if tostring(n.chain or "")==id then n.chain=nil end; out[#out+1]=n end
        end
        if not removed then write_json({ok=false,error="NODE_NOT_FOUND"}); return end
        write_json_file("/etc/fastc/nodes.json",out)
        local groups=read_json("/etc/fastc/groups.json",{}); for g,v in pairs(groups) do if tostring(v)==id then groups[g]=nil end end; write_json_file("/etc/fastc/groups.json",groups)
        restart_manager(); write_json({ok=true,id=id,total=#out}); return
    end

    write_json({ok=false,error="BAD_ACTION"})
end
