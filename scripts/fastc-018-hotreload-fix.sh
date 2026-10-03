#!/bin/sh
set -eu

CTRL="/usr/lib/lua/luci/controller/fastc.lua"
GEN="/usr/libexec/fastc-generate.lua"
VIEW="/usr/lib/lua/luci/view/fastc/console_v018.htm"
STAMP="$(date +%Y%m%d-%H%M%S)"
BAK="/etc/fastc/hotreload-backup-$STAMP"
TMP="/tmp/fastc-hotreload-$$"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT INT TERM

mkdir -p "$BAK" "$TMP"
cp -af "$CTRL" "$BAK/fastc.lua"
cp -af "$GEN" "$BAK/fastc-generate.lua"
[ -f "$VIEW" ] && cp -af "$VIEW" "$BAK/console_v018.htm" || true

echo "=================================================="
echo " FastC 0.1.8 HotReload Fix"
echo " no mihomo process restart for chain/group changes"
echo "=================================================="

FC_CTRL="$CTRL" FC_OUT="$TMP/fastc.lua" lua <<'LUA'
local src=os.getenv("FC_CTRL")
local out=os.getenv("FC_OUT")
local f=assert(io.open(src,"rb")); local s=f:read("*a"); f:close()

local function replace_once(buf,old,new,label)
  local a,b=buf:find(old,1,true)
  assert(a,label.." pattern not found")
  assert(not buf:find(old,b+1,true),label.." pattern is duplicated")
  return buf:sub(1,a-1)..new..buf:sub(b+1)
end

local old_restart=[=[local function restart_manager()
    local sys=require "luci.sys"
    local gen,err=generate_config(); if not gen then return nil,err end
    if sys.call("/etc/init.d/fastc running >/dev/null 2>&1")==0 then
        if sys.call("/etc/init.d/fastc restart >/tmp/fastc-restart.log 2>&1")~=0 then return nil,sys.exec("cat /tmp/fastc-restart.log 2>/dev/null") end
        sys.call("sleep 1")
    end
    return gen
end]=]

local new_restart=[=[local function restart_manager()
    local sys=require "luci.sys"; local jsonc=require "luci.jsonc"
    local gen,err=generate_config(); if not gen then return nil,err end

    -- Validate before applying. This catches bad generated configs without
    -- touching the currently running mihomo instance.
    if sys.call("/usr/bin/mihomo -t -d /etc/fastc -f /etc/fastc/config.yaml >/tmp/fastc-hotcheck.log 2>&1")~=0 then
        return nil,sys.exec("cat /tmp/fastc-hotcheck.log 2>/dev/null")
    end

    if sys.call("/etc/init.d/fastc running >/dev/null 2>&1")==0 then
        local payload=jsonc.stringify({path="/etc/fastc/config.yaml"})
        local code=trim(sys.exec("curl -fsS --connect-timeout 1 --max-time 5 -o /tmp/fastc-hotreload.body -w '%{http_code}' -X PUT -H 'Content-Type: application/json' --data "..shell_quote(payload).." 'http://127.0.0.1:9097/configs?force=true' 2>/tmp/fastc-hotreload.log") or "")
        if code~="204" and code~="200" then
            local d=trim(sys.exec("cat /tmp/fastc-hotreload.log /tmp/fastc-hotreload.body 2>/dev/null") or "")
            return nil,"mihomo hot reload failed http="..code.." "..d
        end
        -- Re-assert saved selector choices after config hot reload.
        sys.call("lua /usr/libexec/fastc-sync.lua >/tmp/fastc-hot-sync.json 2>/tmp/fastc-hot-sync.log")
        return gen
    end

    -- Only start the service when it was not running at all.
    if sys.call("/etc/init.d/fastc start >/tmp/fastc-start.log 2>&1")~=0 then
        return nil,sys.exec("cat /tmp/fastc-start.log /tmp/fastc-mihomo-check.log 2>/dev/null")
    end
    return gen
end]=]

s=replace_once(s,old_restart,new_restart,"restart_manager")

local old_select=[=[    if action=="select_group" then
        local group=http.formvalue("group") or ""; local id=http.formvalue("id") or ""
        if not valid_group(group) or group=="" then write_json({ok=false,error="BAD_GROUP"}); return end
        local nodes=read_json("/etc/fastc/nodes.json",{})
        if id~="" then local n=find_node(nodes,id); if not n or n.group~=group then write_json({ok=false,error="NODE_NOT_IN_GROUP"}); return end end
        local groups=read_json("/etc/fastc/groups.json",{}); local old=groups[group]; groups[group]=(id~="" and id or nil)
        if not write_json_file("/etc/fastc/groups.json",groups) then write_json({ok=false,error="WRITE_FAILED"}); return end
        local gen,err=restart_manager()
        if not gen then groups[group]=old; write_json_file("/etc/fastc/groups.json",groups); restart_manager(); write_json({ok=false,error="GROUP_RELOAD_FAILED",detail=err}); return end
        write_json({ok=true,group=group,id=id}); return
    end]=]

local new_select=[=[    if action=="select_group" then
        local group=http.formvalue("group") or ""; local id=http.formvalue("id") or ""
        if not valid_group(group) or group=="" then write_json({ok=false,error="BAD_GROUP"}); return end
        local nodes=read_json("/etc/fastc/nodes.json",{})
        if id~="" then local n=find_node(nodes,id); if not n or n.group~=group then write_json({ok=false,error="NODE_NOT_IN_GROUP"}); return end end

        local selected=id
        if selected=="" then
            for _,n in ipairs(nodes) do if n.group==group then selected=tostring(n.id or ""); if selected~="" then break end end end
            if selected=="" then selected="REJECT" end
        end

        local groups=read_json("/etc/fastc/groups.json",{}); local old=groups[group]; groups[group]=(id~="" and id or nil)
        if not write_json_file("/etc/fastc/groups.json",groups) then write_json({ok=false,error="WRITE_FAILED"}); return end

        -- Group selection is already represented inside the running mihomo
        -- selector. Do not regenerate or restart the whole core.
        local payload=jsonc.stringify({name=selected})
        local code=trim(sys.exec("curl -fsS --connect-timeout 1 --max-time 3 -o /tmp/fastc-select.body -w '%{http_code}' -X PUT -H 'Content-Type: application/json' --data "..shell_quote(payload).." "..shell_quote("http://127.0.0.1:9097/proxies/FASTC-"..group).." 2>/tmp/fastc-select.log") or "")
        if code~="204" and code~="200" then
            groups[group]=old; write_json_file("/etc/fastc/groups.json",groups)
            write_json({ok=false,error="GROUP_SELECT_FAILED",detail="mihomo selector API http="..code.." "..trim(sys.exec("cat /tmp/fastc-select.log /tmp/fastc-select.body 2>/dev/null") or "")}); return
        end
        write_json({ok=true,group=group,id=id,selected=selected,hot=true}); return
    end]=]

s=replace_once(s,old_select,new_select,"select_group")

local wf=assert(io.open(out,"wb")); wf:write(s); wf:close()
LUA

FC_LUA_CHECK="$TMP/fastc.lua" lua -e 'local p=os.getenv("FC_LUA_CHECK"); assert(loadfile(p))'

# Router optimization recommended by mihomo docs: do not do process matching.
FC_GEN="$GEN" FC_OUT="$TMP/fastc-generate.lua" lua <<'LUA'
local src=os.getenv("FC_GEN"); local out=os.getenv("FC_OUT")
local f=assert(io.open(src,"rb")); local s=f:read("*a"); f:close()
if not s:find("find-process-mode: off",1,true) then
  local old='"mode: rule","log-level: warning","allow-lan: true"'
  local new='"mode: rule","log-level: warning","find-process-mode: off","allow-lan: true"'
  local a,b=s:find(old,1,true); assert(a,"generator general config pattern not found")
  s=s:sub(1,a-1)..new..s:sub(b+1)
end
local wf=assert(io.open(out,"wb")); wf:write(s); wf:close()
LUA
FC_LUA_CHECK="$TMP/fastc-generate.lua" lua -e 'local p=os.getenv("FC_LUA_CHECK"); assert(loadfile(p))'

cp -af "$TMP/fastc.lua" "$CTRL"
cp -af "$TMP/fastc-generate.lua" "$GEN"
chmod 0644 "$CTRL"
chmod 0755 "$GEN"

uci set fastc.main.version='0.1.8-hot1'
uci commit fastc

if [ -f "$VIEW" ]; then
  sed -i 's/FastC 0\.1\.8 开发控制台/FastC 0.1.8 HotReload 控制台/g' "$VIEW"
fi

# Validate the currently generated config; do not restart mihomo here.
lua "$GEN" >/tmp/fastc-hotfix-generate.json 2>/tmp/fastc-hotfix-generate.log
/usr/bin/mihomo -t -d /etc/fastc -f /etc/fastc/config.yaml >/tmp/fastc-hotfix-check.log 2>&1

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] FastC 0.1.8 HotReload Fix installed"
echo "[OK] A-group selector changes now use mihomo API only"
echo "[OK] assign/chain changes use PUT /configs?force=true without restarting mihomo"
echo "[OK] find-process-mode=off enabled for router workload"
echo "[INFO] Running mihomo PID was not restarted by this installer"
echo "[INFO] Backup: $BAK"
