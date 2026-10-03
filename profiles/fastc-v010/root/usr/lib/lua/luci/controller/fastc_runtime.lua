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
local function selector_map()
    local out={}
    for _,ap in ipairs((topology().aps or {})) do
        local g=tostring(ap.group or ("A"..tostring(ap.slot or "")))
        local o=api_json("/proxies/FASTC-"..g)
        if type(o)=="table" then out[g]={now=o.now or "",alive=o.alive,ssid=ap.ssid or g,subnet=ap.subnet or ""} end
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
local function quick_ip(port,tag)
    local sys=require "luci.sys"
    local proxy="127.0.0.1:"..tostring(port)
    local log="/tmp/fastc-ip-"..tostring(tag or "probe")..".log"
    sys.call(": > "..log)
    local urls={"http://api.ipify.org","https://icanhazip.com"}
    for _,url in ipairs(urls) do
        local cmd="curl -4 -fsS --http1.1 --connect-timeout 2 --max-time 4 --socks5-hostname "..proxy.." "..shq(url).." 2>>"..log
        local ip=trim(sys.exec(cmd) or "")
        if valid_ip(ip) then return ip,url end
    end
    return "",nil
end
local function quick_node_probe(id,port)
    local sys=require "luci.sys"; local jsonc=require "luci.jsonc"
    local safe=tostring(id):gsub("[^%w%-_]","")
    local dfile="/tmp/fastc-delay-"..safe..".json"
    local ifile="/tmp/fastc-ip-"..safe..".txt"
    local elog="/tmp/fastc-probe-"..safe..".log"
    local durl="http://127.0.0.1:9097/proxies/"..id.."/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=3500&expected=204"
    local cmd="rm -f "..dfile.." "..ifile.." "..elog.."; "..
      "(curl -sS --connect-timeout 1 --max-time 5 "..shq(durl).." >"..dfile.." 2>>"..elog..") & p1=$!; "..
      "(curl -4 -fsS --http1.1 --connect-timeout 2 --max-time 4 --socks5-hostname 127.0.0.1:"..tostring(port).." http://api.ipify.org >"..ifile.." 2>>"..elog..") & p2=$!; "..
      "wait $p1 >/dev/null 2>&1 || true; wait $p2 >/dev/null 2>&1 || true"
    sys.call(cmd)
    local draw=trim(sys.exec("cat "..dfile.." 2>/dev/null") or "")
    local iout=trim(sys.exec("cat "..ifile.." 2>/dev/null") or "")
    local ok,obj=pcall(jsonc.parse,draw)
    local delay=ok and type(obj)=="table" and tonumber(obj.delay or "") or nil
    local ip=valid_ip(iout) and iout or ""
    if ip=="" then ip=select(1,quick_ip(port,safe)) end
    local detail=trim(sys.exec("cat "..elog.." 2>/dev/null") or "")
    return delay,ip,detail
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

        local delay,ip,detail=quick_node_probe(id,port)
        n.last_check=os.time(); n.last_delay=delay; n.last_ip=(ip~="" and ip or nil)
        n.last_ok=(delay and delay>0 and ip~="") and true or false
        if n.last_ok then n.last_error=nil else n.last_error=detail~="" and detail or "delay/ip probe failed" end
        write_json_file("/etc/fastc/nodes.json",nodes)
        if n.last_ok then write_json({ok=true,id=id,delay=delay,ip=ip}); return end
        write_json({ok=false,error="NODE_PROBE_FAILED",id=id,delay=delay,ip=ip,detail=n.last_error}); return
    end

    if action=="probe_group" then
        local group=http.formvalue("group") or ""
        local exists,ap=group_exists(group)
        if not exists then write_json({ok=false,error="BAD_GROUP"}); return end
        local idx=tonumber(ap.slot or group:match("^A(%d+)$") or "")
        if not idx then write_json({ok=false,error="BAD_GROUP_SLOT"}); return end
        if not ensure_core() then write_json({ok=false,error="MIHOMO_NOT_RUNNING"}); return end
        local sync_ok,sync_detail=sync_selectors()
        if not sync_ok then write_json({ok=false,error="SELECTOR_SYNC_FAILED",detail=sync_detail}); return end
        local one=api_json("/proxies/FASTC-"..group) or {}
        local now=tostring(one.now or "")
        if now=="" or now=="REJECT" then write_json({ok=false,error="GROUP_REJECTED",selected=now,detail="mihomo selector FASTC-"..group.." currently has no usable node"}); return end
        local base=tonumber(uci:get("fastc","main","probe_port_base") or "18100") or 18100
        local port=base+idx
        if not listener(port) then write_json({ok=false,error="GROUP_PROBE_LISTENER_MISSING",selected=now,detail="probe port "..tostring(port).." is not listening"}); return end
        local ip,ip_source=quick_ip(port,"group-"..group)
        if ip=="" then write_json({ok=false,error="GROUP_EXIT_PROBE_FAILED",group=group,selected=now,detail=trim(sys.exec("cat /tmp/fastc-ip-group-"..group..".log 2>/dev/null") or "")}); return end
        write_json({ok=true,group=group,ssid=ap.ssid or group,subnet=ap.subnet or "",selected=now,ip=ip,ip_source=ip_source}); return
    end

    write_json({ok=false,error="BAD_ACTION"})
end
