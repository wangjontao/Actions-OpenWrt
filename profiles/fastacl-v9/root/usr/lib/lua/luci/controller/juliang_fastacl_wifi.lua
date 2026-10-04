module("luci.controller.juliang_fastacl_wifi",package.seeall)
function index()
    local s=entry({"admin","services","juliang_fastacl_wifi_status"},call("status"),nil)
    s.leaf=true;s.acl_depends={"juliang-fastacl-operator"}
    local a=entry({"admin","services","juliang_fastacl_wifi"},post("change"),nil)
    a.leaf=true;a.acl_depends={"juliang-fastacl-operator"}
end
local function respond(v)
    local http=require "luci.http"
    http.prepare_content("application/json");http.write(require("luci.jsonc").stringify(v))
end
function status()
    local http=require "luci.http"
    local id=http.formvalue("job")
    if id then
        if not id:match("^%d+%-%d+%-%d+$") then respond({ok=false,error="任务编号无效"});return end
        local json=require "luci.jsonc"
        respond(json.parse(require("nixio.fs").readfile("/tmp/juliang-fastacl-wifi/"..id..".json") or "") or {ok=false,error="任务不存在"})
    else respond(require("juliang_fastacl_wifi_env").status(require("luci.model.uci").cursor())) end
end
function change()
    local http=require "luci.http"
    local json=require "luci.jsonc"
    local fs=require "nixio.fs"
    local req=json.parse(http.formvalue("request") or "")
    if type(req)~="table" then respond({ok=false,error="请求格式错误"});return end
    local u=require("luci.model.uci").cursor()
    local env=require "juliang_fastacl_wifi_env"
    local model=require "juliang_fastacl_wifi"
    if env.pending(u) then respond({ok=false,error="存在未提交配置，请先保存或撤销"});return end
    local ok,plan=pcall(model.plan,u,req,env)
    if not ok then respond({ok=false,error=tostring(plan)});return end
    if http.formvalue("preview")=="1" then respond({ok=true,plan=plan});return end
    if req.revision~=plan.revision then respond({ok=false,error="配置已改变，请重新预览"});return end
    if not fs.mkdir("/tmp/juliang-fastacl-wifi.lock","700") then respond({ok=false,error="已有无线任务正在执行"});return end
    fs.mkdirr("/tmp/juliang-fastacl-wifi");fs.chmod("/tmp/juliang-fastacl-wifi","700")
    local id=os.time().."-"..require("nixio").getpid().."-"..math.random(100000,999999)
    local dir="/tmp/juliang-fastacl-wifi/"
    local saved=fs.writefile(dir..id..".request",json.stringify(req)) and fs.writefile(dir..id..".json",json.stringify({ok=true,state="queued"}))
    if not saved then fs.remove(dir..id..".request");fs.rmdir("/tmp/juliang-fastacl-wifi.lock");respond({ok=false,error="无法保存任务"});return end
    fs.chmod(dir..id..".request","600")
    local rc=require("luci.sys").call("(sleep 2; lua /usr/libexec/juliang-fastacl-wifi.lua "..id.." >/tmp/juliang-fastacl-wifi/worker.log 2>&1) </dev/null >/dev/null 2>&1 &")
    if rc~=0 then fs.remove(dir..id..".request");fs.rmdir("/tmp/juliang-fastacl-wifi.lock");respond({ok=false,error="无法启动任务"});return end
    respond({ok=true,job=id,state="queued"})
end
