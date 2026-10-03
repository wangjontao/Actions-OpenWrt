module("luci.controller.fastc_topology", package.seeall)

function index()
    local e=entry({"admin","services","fastc_topology_api"},call("handle"),nil)
    e.leaf=true; e.dependent=false; e.acl_depends={"fastc"}
end

local function write_json(t)
    local http=require "luci.http"
    http.prepare_content("application/json")
    http.write(require("luci.jsonc").stringify(t))
end
local function read_json(path)
    local f=io.open(path,"rb"); if not f then return nil end
    local raw=f:read("*a") or ""; f:close()
    local ok,obj=pcall(require("luci.jsonc").parse,raw)
    if ok and type(obj)=="table" then return obj end
    return nil
end

function handle()
    local http=require "luci.http"
    local sys=require "luci.sys"
    local action=http.formvalue("action") or "status"
    if action~="status" and action~="refresh" then write_json({ok=false,error="BAD_ACTION"}); return end

    local need=true
    local topo=read_json("/etc/fastc/topology.json")
    if action=="status" and topo and tonumber(topo.updated or 0)>0 and os.time()-tonumber(topo.updated or 0)<10 then need=false end
    if need then
        sys.call("lua /usr/libexec/fastc-discover.lua >/tmp/fastc-topology.json 2>/tmp/fastc-topology.log || true")
        topo=read_json("/etc/fastc/topology.json")
    end
    if not topo then
        write_json({ok=false,error="TOPOLOGY_UNAVAILABLE",detail=sys.exec("cat /tmp/fastc-topology.log 2>/dev/null") or ""}); return
    end
    topo.ok=true
    write_json(topo)
end
