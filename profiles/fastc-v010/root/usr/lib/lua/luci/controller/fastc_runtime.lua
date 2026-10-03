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
    local raw=sys.exec("curl -fsS --max-time 2 "..shq("http://127.0.0.1:9097"..path).." 2>/dev/null") or ""
    local ok,obj=pcall(jsonc.parse,raw)
    if ok and type(obj)=="table" then return obj end
    return nil
end
local function selector_map()
    local all=api_json("/proxies") or {}
    local p=all.proxies or {}
    local out={}
    for _,ap in ipairs((topology().aps or {})) do
        local g=tostring(ap.group or ("A"..tostring(ap.slot or "")))
        local o=p["FASTC-"..g]
        if type(o)=="table" then out[g]={now=o.now or "",all=o.all or {},alive=o.alive,ssid=ap.ssid or g,subnet=ap.subnet or ""} end
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
    local api=sys.call("curl -fsS --max-time 1 http://127.0.0.1:9097/version >/dev/null 2>&1")==0
    local l=listener(port)
    local tproxy=sys.call("nft list table inet fastc_tproxy >/dev/null 2>&1")==0
    local ks=sys.call("nft list table inet fastc_killswitch >/dev/null 2>&1")==0
    local route=sys.call("ip rule show 2>/dev/null | grep -q 'lookup "..table_id.."'")==0
    return {pid=pid,api=api,listener=l,tproxy=tproxy,killswitch=ks,route=route,healthy=(pid and api and l and tproxy and ks and route),selectors=(api and selector_map() or {})}
end
local function ensure_core()
    local sys=require "luci.sys"
    if sys.call("pidof mihomo >/dev/null 2>&1")==0 and sys.call("curl -fsS --max-time 1 http://127.0.0.1:9097/version >/dev/null 2>&1")==0 then
        sync_selectors()
        return true
    end
    sys.call("/etc/init.d/fastc restart >/tmp/fastc-runtime-restart.log 2>&1")
    sys.call("sleep 2")
    local ok=sys.call("pidof mihomo >/dev/null 2>&1")==0 and sys.call("curl -fsS --max-time 1 http://127.0.0.1:9097/version >/dev/null 2>&1")==0
    if ok then sync_selectors() end
    return ok
end
local function valid_ip(ip)
    return tostring(ip or ""):match("^%d+%.%d+%.%d+%.%d+$")~=nil
end
local function probe_ip(port,logfile)
    local sys=require "luci.sys"
    local proxy="127.0.0.1:"..tostring(port)
    local urls={"http://api.ipify.org","http://ifconfig.me/ip","https://api.ipify.org","https://icanhazip.com"}
    sys.call(": > "..logfile)
    for _,url in ipairs(urls) do
        local cmd="curl -4 -fsS --http1.1 --connect-timeout 5 --max-time 10 --socks5-hostname "..proxy.." "..shq(url).." 2>>"..logfile
        local ip=trim(sys.exec(cmd) or "")
        if valid_ip(ip) then return ip,url end
    end
    return "",nil
end
local function probe_https_204(port,logfile)
    local sys=require "luci.sys"
    sys.call(": > "..logfile)
    local cmd="curl -4 -sS --http1.1 --connect-timeout 5 --max-time 10 --socks5-hostname 127.0.0.1:"..tostring(port).." -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>>"..logfile
    local code=trim(sys.exec(cmd) or "")
    return code=="204",code
end

function handle()
    local http=require "luci.http"
    local sys=require "luci.sys"
    local jsonc=require "luci.jsonc"
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
        local num=tonumber(id:match("^n(%d+)$") or "")
        if not num then write_json({ok=false,error="BAD_NODE"}); return end
        local nodes=read_json("/etc/fastc/nodes.json",{})
        local n=find_node(nodes,id)
        if not n then write_json({ok=false,error="NODE_NOT_FOUND"}); return end
        if not ensure_core() then write_json({ok=false,error="MIHOMO_NOT_RUNNING",detail=trim(sys.exec("cat /tmp/fastc-runtime-restart.log /tmp/fastc-mihomo-check.log 2>/dev/null") or "")}); return end

        local base=tonumber(uci:get("fastc","main","node_probe_port_base") or "18200") or 18200
        local port=base+num
        if port>65535 or not listener(port) then write_json({ok=false,error="NODE_PROBE_LISTENER_MISSING",detail="probe port "..tostring(port).." is not listening"}); return end

        local durl="http://127.0.0.1:9097/proxies/"..id.."/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=8000&expected=204"
        local draw=sys.exec("curl -sS --max-time 10 "..shq(durl).." 2>/tmp/fastc-probe-delay.log") or ""
        local pok,dobj=pcall(jsonc.parse,draw)
        local delay=pok and type(dobj)=="table" and tonumber(dobj.delay or "") or nil
        local https_ok,https_code=probe_https_204(port,"/tmp/fastc-probe-https.log")
        local ip,ip_source=probe_ip(port,"/tmp/fastc-probe-ip.log")

        n.last_check=os.time(); n.last_delay=delay; n.last_ip=(ip~="" and ip or nil)
        n.last_ok=(delay and delay>0 and ip~="") and true or false
        if n.last_ok then n.last_error=nil else n.last_error="delay="..tostring(draw).."; https204="..tostring(https_code).."; ip="..trim(sys.exec("cat /tmp/fastc-probe-ip.log 2>/dev/null") or "") end
        write_json_file("/etc/fastc/nodes.json",nodes)
        if n.last_ok then write_json({ok=true,id=id,delay=delay,ip=ip,ip_source=ip_source,https_ok=https_ok,https_code=https_code}); return end
        write_json({ok=false,error="NODE_PROBE_FAILED",id=id,delay=delay,ip=ip,https_ok=https_ok,https_code=https_code,detail=n.last_error}); return
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
        local selectors=selector_map()
        local now=(selectors[group] and selectors[group].now) or ""
        if now=="" or now=="REJECT" then write_json({ok=false,error="GROUP_REJECTED",selected=now,detail="mihomo selector FASTC-"..group.." currently has no usable node"}); return end
        local base=tonumber(uci:get("fastc","main","probe_port_base") or "18100") or 18100
        local port=base+idx
        if not listener(port) then write_json({ok=false,error="GROUP_PROBE_LISTENER_MISSING",selected=now,detail="probe port "..tostring(port).." is not listening"}); return end
        local https_ok,https_code=probe_https_204(port,"/tmp/fastc-group-https.log")
        local ip,ip_source=probe_ip(port,"/tmp/fastc-group-probe.log")
        if ip=="" then write_json({ok=false,error="GROUP_EXIT_PROBE_FAILED",group=group,selected=now,https_ok=https_ok,https_code=https_code,detail=trim(sys.exec("cat /tmp/fastc-group-probe.log /tmp/fastc-group-https.log 2>/dev/null") or "")}); return end
        write_json({ok=true,group=group,ssid=ap.ssid or group,subnet=ap.subnet or "",selected=now,ip=ip,ip_source=ip_source,https_ok=https_ok,https_code=https_code}); return
    end

    write_json({ok=false,error="BAD_ACTION"})
end
