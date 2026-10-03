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
local function topology()
    return read_json("/etc/fastc/topology.json",{aps={}})
end
local function group_exists(group)
    for _,ap in ipairs((topology().aps or {})) do
        local g=tostring(ap.group or ("A"..tostring(ap.slot or "")))
        if g==group then return true,ap end
    end
    return false,nil
end
local function api_json(path)
    local sys=require "luci.sys"; local jsonc=require "luci.jsonc"
    local raw=sys.exec("curl -fsS --connect-timeout 1 --max-time 2 "..shq("http://127.0.0.1:9097"..path).." 2>/dev/null") or ""
    local ok,obj=pcall(jsonc.parse,raw)
    if ok and type(obj)=="table" then return obj end
    return nil
end
local function api_select(name,node)
    local sys=require "luci.sys"; local jsonc=require "luci.jsonc"
    local payload=jsonc.stringify({name=node})
    return sys.call("curl -fsS --connect-timeout 1 --max-time 2 -o /dev/null -X PUT -H 'Content-Type: application/json' --data "..shq(payload).." "..shq("http://127.0.0.1:9097/proxies/"..name).." >/dev/null 2>&1")==0
end

-- Read all selector state with ONE local API request. 0.1.7/early 0.1.8
-- queried FASTC-A1, A2, A3... separately and created needless curl churn.
local function selector_map()
    local all=api_json("/proxies") or {}
    local p=type(all.proxies)=="table" and all.proxies or {}
    local out={}
    for _,ap in ipairs((topology().aps or {})) do
        local g=tostring(ap.group or ("A"..tostring(ap.slot or "")))
        local o=p["FASTC-"..g]
        if type(o)=="table" then
            out[g]={now=o.now or "",alive=o.alive,ssid=ap.ssid or g,subnet=ap.subnet or ""}
        end
    end
    return out
end
local function sync_selectors()
    local sys=require "luci.sys"
    local raw=sys.exec("lua /usr/libexec/fastc-sync.lua 2>/tmp/fastc-sync.log") or ""
    local ok,obj=pcall(require("luci.jsonc").parse,raw)
    if ok and type(obj)=="table" and obj.ok==true then return true,obj end
    local d=trim(sys.exec("cat /tmp/fastc-sync.log 2>/dev/null") or "")
    return false,(d~="" and d or raw)
end
local function runtime_status(uci)
    local sys=require "luci.sys"
    local port=tonumber(uci:get("fastc","main","tproxy_port") or "7895") or 7895
    local table_id=uci:get("fastc","main","route_table") or "101"
    local pid=sys.call("pidof mihomo >/dev/null 2>&1")==0
    local api=sys.call("curl -fsS --connect-timeout 1 --max-time 1 http://127.0.0.1:9097/version >/dev/null 2>&1")==0
    local l=listener(port)
    local tproxy=sys.call("nft list table inet fastc_tproxy >/dev/null 2>&1")==0
    local ks=sys.call("nft list table inet fastc_killswitch >/dev/null 2>&1")==0
    local route=sys.call("ip rule show 2>/dev/null | grep -q 'lookup "..table_id.."'")==0
    return {pid=pid,api=api,listener=l,tproxy=tproxy,killswitch=ks,route=route,healthy=(pid and api and l and tproxy and ks and route),selectors=(api and selector_map() or {})}
end
local function ensure_core()
    local sys=require "luci.sys"
    if sys.call("pidof mihomo >/dev/null 2>&1")==0 and sys.call("curl -fsS --connect-timeout 1 --max-time 1 http://127.0.0.1:9097/version >/dev/null 2>&1")==0 then
        return true
    end
    sys.call("/etc/init.d/fastc restart >/tmp/fastc-runtime-restart.log 2>&1")
    sys.call("sleep 1")
    return sys.call("pidof mihomo >/dev/null 2>&1")==0 and sys.call("curl -fsS --connect-timeout 1 --max-time 1 http://127.0.0.1:9097/version >/dev/null 2>&1")==0
end
local function valid_ip(ip)
    local a,b,c,d=tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a,b,c,d=tonumber(a),tonumber(b),tonumber(c),tonumber(d)
    return a and b and c and d and a<=255 and b<=255 and c<=255 and d<=255
end

-- Single-connection probe: one HTTP request through the selected SOCKS path
-- returns both the real exit IP and time_starttransfer. This replaces the old
-- parallel mihomo /delay + separate IP request which doubled chain handshakes.
local function one_probe(port,tag)
    local sys=require "luci.sys"
    local proxy="127.0.0.1:"..tostring(port)
    local safe=tostring(tag or "probe"):gsub("[^%w%-_]","")
    local log="/tmp/fastc-probe-"..safe..".log"
    local urls={"http://api.ipify.org","http://ifconfig.me/ip"}
    sys.call(": > "..log)
    for _,url in ipairs(urls) do
        local cmd="curl -4 -fsS --http1.1 --connect-timeout 1 --max-time 3 --socks5-hostname "..proxy.." -w '\\n%{time_starttransfer}' "..shq(url).." 2>>"..log
        local raw=sys.exec(cmd) or ""
        local body,sec=raw:match("^(.-)\n([%d%.]+)%s*$")
        local ip=trim(body or "")
        local t=tonumber(sec or "")
        if valid_ip(ip) and t then
            local ms=math.floor(t*1000+0.5)
            return ms,ip,url,""
        end
    end
    return nil,"",nil,trim(sys.exec("cat "..log.." 2>/dev/null") or "")
end

function handle()
    local http=require "luci.http"
    local sys=require "luci.sys"
    local uci=require("uci").cursor()
    local action=http.formvalue("action") or "status"

    if action=="status" then
        write_json({ok=true,runtime=runtime_status(uci),topology=topology()})
        return
    end

    if action=="sync_selectors" then
        if not ensure_core() then write_json({ok=false,error="MIHOMO_NOT_RUNNING"}); return end
        local ok,detail=sync_selectors()
        if ok then write_json({ok=true,detail=detail,selectors=selector_map()}) else write_json({ok=false,error="SELECTOR_SYNC_FAILED",detail=detail}) end
        return
    end

    if action=="probe_node" then
        local id=http.formvalue("id") or ""
        if not id:match("^n%d+$") then write_json({ok=false,error="BAD_NODE"}); return end
        local nodes=read_json("/etc/fastc/nodes.json",{})
        local n=find_node(nodes,id)
        if not n then write_json({ok=false,error="NODE_NOT_FOUND"}); return end
        if not ensure_core() then write_json({ok=false,error="MIHOMO_NOT_RUNNING",detail=trim(sys.exec("cat /tmp/fastc-runtime-restart.log /tmp/fastc-mihomo-check.log 2>/dev/null") or "")}); return end

        local port=tonumber(uci:get("fastc","main","node_probe_port") or uci:get("fastc","main","node_probe_port_base") or "18200") or 18200
        if not listener(port) then write_json({ok=false,error="NODE_PROBE_LISTENER_MISSING",detail="shared probe port "..tostring(port).." is not listening"}); return end
        if not api_select("FASTC-NODE-PROBE",id) then write_json({ok=false,error="NODE_PROBE_SELECT_FAILED",detail="cannot select "..id.." in FASTC-NODE-PROBE"}); return end

        local delay,ip,source,detail=one_probe(port,id)
        n.last_check=os.time(); n.last_delay=delay; n.last_ip=(ip~="" and ip or nil)
        n.last_ok=(delay and delay>0 and ip~="") and true or false
        if n.last_ok then n.last_error=nil else n.last_error=detail~="" and detail or "single connection IP probe failed" end
        write_json_file("/etc/fastc/nodes.json",nodes)
        if n.last_ok then write_json({ok=true,id=id,delay=delay,ip=ip,ip_source=source,probe_mode="single_connection"}); return end
        write_json({ok=false,error="NODE_PROBE_FAILED",id=id,delay=delay,ip=ip,detail=n.last_error}); return
    end

    if action=="probe_group" then
        local group=http.formvalue("group") or ""
        local exists,ap=group_exists(group)
        if not exists then write_json({ok=false,error="BAD_GROUP"}); return end
        local idx=tonumber(ap.slot or group:match("^A(%d+)$") or "")
        if not idx then write_json({ok=false,error="BAD_GROUP_SLOT"}); return end
        if not ensure_core() then write_json({ok=false,error="MIHOMO_NOT_RUNNING"}); return end

        local selectors=selector_map()
        local now=(selectors[group] and selectors[group].now) or ""
        if now=="" then
            local sync_ok,sync_detail=sync_selectors()
            if not sync_ok then write_json({ok=false,error="SELECTOR_SYNC_FAILED",detail=sync_detail}); return end
            selectors=selector_map(); now=(selectors[group] and selectors[group].now) or ""
        end
        if now=="" or now=="REJECT" then write_json({ok=false,error="GROUP_REJECTED",selected=now,detail="mihomo selector FASTC-"..group.." currently has no usable node"}); return end

        local base=tonumber(uci:get("fastc","main","probe_port_base") or "18100") or 18100
        local port=base+idx
        if not listener(port) then write_json({ok=false,error="GROUP_PROBE_LISTENER_MISSING",selected=now,detail="probe port "..tostring(port).." is not listening"}); return end
        local delay,ip,source,detail=one_probe(port,"group-"..group)
        if ip=="" then write_json({ok=false,error="GROUP_EXIT_PROBE_FAILED",group=group,selected=now,detail=detail}); return end
        write_json({ok=true,group=group,ssid=ap.ssid or group,subnet=ap.subnet or "",selected=now,ip=ip,delay=delay,ip_source=source,probe_mode="single_connection"}); return
    end

    write_json({ok=false,error="BAD_ACTION"})
end
