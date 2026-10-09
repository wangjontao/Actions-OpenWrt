module("luci.controller.juliang_fastacl_runtime", package.seeall)
function index()
    local s=entry({"admin","services","juliang_fastacl_runtime"},call("status"),nil)
    s.leaf=true; s.acl_depends={"juliang-fastacl-operator"}
    local e=entry({"admin","services","juliang_fastacl_runtime_set"},post("set_mode"),nil)
    e.leaf=true; e.acl_depends={"juliang-fastacl-operator"}
end
local function respond(command)
    local http=require "luci.http"
    local json=require "luci.jsonc"
    local raw=require("luci.sys").exec(command)
    local ok,data=pcall(json.parse,raw)
    http.prepare_content("application/json")
    http.write(json.stringify(ok and type(data)=="table" and data or {ok=false,error="ENGINE_ERROR"}))
end
function status() respond("/usr/bin/juliang-fastacl-runtime status") end
function set_mode()
    local mode=require("luci.http").formvalue("mode")
    if mode~="fastacl" and mode~="normal_proxy" then
        require("luci.http").status(400,"Bad mode"); return
    end
    respond("/usr/bin/juliang-fastacl-runtime set "..mode)
end
