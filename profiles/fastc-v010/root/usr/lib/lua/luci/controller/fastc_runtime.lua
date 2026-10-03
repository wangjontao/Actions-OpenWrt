module("luci.controller.fastc_runtime", package.seeall)

function index()
    local e=entry({"admin","services","fastc_runtime_api"},call("handle"),nil)
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
    local f=io.open(path,"wb"); if not f then return false end
    f:write(require("luci.jsonc").stringify(obj,true)); f:close(); return true
end
local function trim(s) return (tostring(s or ""):gsub("^%s+",""):gsub("%s+$","")) end
local function shq(s) return "'"..tostring(s or ""):gsub("'","'\\''").."'" end
local function find_node(nodes,id)
    for _,n in ipairs(nodes) do if tostring(n.id)==tostring(id) then return n end end
    return nil
end
local function listener(port)
    local sys=require "luci.sys"
    return sys.call("ss -lnt 2>/dev/null | grep -q ':"..tonumber(port).." ' || netstat -lnt 2>/dev/null | grep -q ':"..tonumber(port).." '")==0
end
local function runtime_status(uci)
    local sys=require "luci.sys"
    local port=tonumber(uci:get("fastc","main","tproxy_port") or "7895") or 7895
    local table_id=uci:get("fastc","main","route_table") or "101"
    local pid=sys.call("pidof mihomo >/dev/null 2>&1")==0
    local api=sys.call("curl -fsS --max-time 1 http://127.0.0.1:9097/version >/dev/null 2>&1")==0
    local l=listener(port)
    local tproxy=sys.call("nft list table inet fastc_tproxy >/dev/null 2>&1")==0
    local ks=sys.call("nft list table inet fastc_killswitch >/dev/null 2>&1")==0
    local route=sys.call("ip rule show 2>/dev/null | grep -q 'lookup "..table_id.."'")==0
    return {pid=pid,api=api,listener=l,tproxy=tproxy,killswitch=ks,route=route,healthy=(pid and api and l and tproxy and ks and route)}
end
local function ensure_core()
    local sys=require "luci.sys"
    if sys.call("pidof mihomo >/dev/null 2>&1")==0 and sys.call("curl -fsS --max-time 1 http://127.0.0.1:9097/version >/dev/null 2>&1")==0 then return true end
    sys.call("/etc/init.d/fastc restart >/tmp/fastc-runtime-restart.log 2>&1")
    sys.call("sleep 2")
    return sys.call("pidof mihomo >/dev/null 2>&1")==0 and sys.call("curl -fsS --max-time 1 http://127.0.0.1:9097/version >/dev/null 2>&1")==0
end

function handle()
    local http=require "luci.http"
    local sys=require "luci.sys"
    local jsonc=require "luci.jsonc"
    local uci=require("uci").cursor()
    local action=http.formvalue("action") or "status"

    if action=="status" then
        write_json({ok=true,runtime=runtime_status(uci)})
        return
    end

    if action=="probe_node" then
        local id=http.formvalue("id") or ""
        local num=tonumber(id:match("^n(%d+)$") or "")
        if not num then write_json({ok=false,error="BAD_NODE"}); return end
        local nodes=read_json("/etc/fastc/nodes.json",{})
        local n=find_node(nodes,id)
        if not n then write_json({ok=false,error="NODE_NOT_FOUND"}); return end

        if not ensure_core() then
            write_json({ok=false,error="MIHOMO_NOT_RUNNING",detail=trim(sys.exec("cat /tmp/fastc-runtime-restart.log /tmp/fastc-mihomo-check.log 2>/dev/null") or "")}); return
        end

        local base=tonumber(uci:get("fastc","main","node_probe_port_base") or "18200") or 18200
        local port=base+num
        if port>65535 or not listener(port) then
            write_json({ok=false,error="NODE_PROBE_LISTENER_MISSING",detail="probe port "..tostring(port).." is not listening"}); return
        end

        local durl="http://127.0.0.1:9097/proxies/"..id.."/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=8000&expected=204"
        local draw=sys.exec("curl -sS --max-time 10 "..shq(durl).." 2>/tmp/fastc-probe-delay.log") or ""
        local pok,dobj=pcall(jsonc.parse,draw)
        local delay=pok and type(dobj)=="table" and tonumber(dobj.delay or "") or nil

        local ip=trim(sys.exec("curl -4 -fsS --connect-timeout 5 --max-time 10 --socks5-hostname 127.0.0.1:"..port.." https://api.ipify.org 2>/tmp/fastc-probe-ip.log") or "")
        if ip=="" then
            ip=trim(sys.exec("curl -4 -fsS --connect-timeout 5 --max-time 10 --socks5-hostname 127.0.0.1:"..port.." https://icanhazip.com 2>>/tmp/fastc-probe-ip.log") or "")
        end
        if not ip:match("^%d+%.%d+%.%d+%.%d+$") then ip="" end

        n.last_check=os.time()
        n.last_delay=delay
        n.last_ip=(ip~="" and ip or nil)
        n.last_ok=(delay and delay>0 and ip~="") and true or false
        if n.last_ok then n.last_error=nil else
            n.last_error="delay="..tostring(draw).."; ip="..trim(sys.exec("cat /tmp/fastc-probe-ip.log 2>/dev/null") or "")
        end
        write_json_file("/etc/fastc/nodes.json",nodes)

        if n.last_ok then write_json({ok=true,id=id,delay=delay,ip=ip}); return end
        write_json({ok=false,error="NODE_PROBE_FAILED",id=id,delay=delay,ip=ip,detail=n.last_error}); return
    end

    if action=="probe_group" then
        local group=http.formvalue("group") or ""
        local idx=tonumber(group:match("^A(%d+)$") or "")
        if not idx or idx<1 or idx>20 then write_json({ok=false,error="BAD_GROUP"}); return end
        if not ensure_core() then write_json({ok=false,error="MIHOMO_NOT_RUNNING"}); return end
        local base=tonumber(uci:get("fastc","main","probe_port_base") or "18100") or 18100
        local port=base+idx
        if not listener(port) then write_json({ok=false,error="GROUP_PROBE_LISTENER_MISSING"}); return end
        local ip=trim(sys.exec("curl -4 -fsS --connect-timeout 5 --max-time 10 --socks5-hostname 127.0.0.1:"..port.." https://api.ipify.org 2>/tmp/fastc-group-probe.log") or "")
        if not ip:match("^%d+%.%d+%.%d+%.%d+$") then write_json({ok=false,error="GROUP_EXIT_PROBE_FAILED",detail=trim(sys.exec("cat /tmp/fastc-group-probe.log 2>/dev/null") or "")}); return end
        write_json({ok=true,group=group,ip=ip}); return
    end

    write_json({ok=false,error="BAD_ACTION"})
end
