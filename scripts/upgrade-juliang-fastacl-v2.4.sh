#!/bin/sh
set -eu
CTRL="/usr/lib/lua/luci/controller/juliang_fastacl.lua"
VIEW="/usr/lib/lua/luci/view/juliang_fastacl/console.htm"
STATIC_DIR="/www/luci-static/resources"
STATIC_JS="$STATIC_DIR/juliang-fastacl-v24.js"
STATIC_URL='https://api.github.com/repos/wangjontao/Actions-OpenWrt/contents/profiles/fastacl-v9/root/www/luci-static/resources/juliang-fastacl-v24.js?ref=5c739d06365484af69d6c4fedd16c5e10e2acca2'

[ -s "$CTRL" ] || { echo "[ERROR] controller missing: $CTRL" >&2; exit 1; }
[ -s "$VIEW" ] || { echo "[ERROR] view missing: $VIEW" >&2; exit 1; }
command -v lua >/dev/null 2>&1 || { echo "[ERROR] lua missing" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[ERROR] curl missing" >&2; exit 1; }
mkdir -p "$STATIC_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/etc/juliang-fastacl/v2.4-fix1-$STAMP"
mkdir -p "$BACKUP"
cp -af "$CTRL" "$BACKUP/controller.lua"
cp -af "$VIEW" "$BACKUP/console.htm"
[ -f "$STATIC_JS" ] && cp -af "$STATIC_JS" "$BACKUP/juliang-fastacl-v24.js" || true
cp -af /etc/config/passwall2 "$BACKUP/passwall2" 2>/dev/null || true
cp -af /etc/config/juliang_fastacl "$BACKUP/juliang_fastacl" 2>/dev/null || true

echo '=================================================='
echo ' JuLiang FastACL 2.4 Fix1'
echo ' rename / single delete / batch delete'
echo '=================================================='
echo "[INFO] Backup: $BACKUP"

curl -4 --http1.1 -fL --connect-timeout 15 --max-time 120 --retry 5 --retry-delay 2 \
  -H 'Accept: application/vnd.github.raw+json' -H 'User-Agent: FastACL-2.4-Fix1' \
  -o "$STATIC_JS" "$STATIC_URL"

grep -q 'FastACL 2.4 控制台' "$STATIC_JS" || { echo '[ERROR] v2.4 JS download validation failed' >&2; exit 1; }
grep -q 'value="重命名"' "$STATIC_JS" || { echo '[ERROR] rename UI missing' >&2; exit 1; }
grep -q 'value="删除选中"' "$STATIC_JS" || { echo '[ERROR] batch delete UI missing' >&2; exit 1; }

JFA_CTRL="$CTRL" lua <<'LUA'
local path=assert(os.getenv('JFA_CTRL'))
local f=assert(io.open(path,'rb')); local s=f:read('*a'); f:close()
local assign=s:find('    if action == "assign" then',1,true)
assert(assign,'assign anchor missing')
local old=s:find('    %-%- JuLiangTK FastACL 2%.4 node admin backend')
if old and old < assign then s=s:sub(1,old-1)..s:sub(assign) end
local block=[=[    -- JuLiangTK FastACL 2.4 node admin backend fix1
    if action == "rename_node" then
        if not node_cfg or node_cfg[".type"] ~= "nodes" or is_special_protocol(node_cfg.protocol or "") then
            write_json({ok=false,error="BAD_NODE"}); return
        end
        local name=(http.formvalue("name") or ""):gsub("^%s+",""):gsub("%s+$","")
        if name=="" or #name>128 or name:find("[%z\1-\31\127]") then
            write_json({ok=false,error="BAD_NAME"}); return
        end
        local old_name=node_cfg.remarks or node
        uci:set("passwall2",node,"remarks",name)
        if not uci:commit("passwall2") then write_json({ok=false,error="RENAME_COMMIT_FAILED"}); return end
        write_json({ok=true,action="rename_node",node=node,old_name=old_name,name=name}); return
    end

    if action == "delete_nodes" then
        local raw=http.formvalue("nodes") or node or ""
        local target,ordered={},{}
        for id in raw:gmatch("[^,]+") do
            id=id:gsub("^%s+",""):gsub("%s+$","")
            if id~="" and not target[id] then
                local cfg=uci:get_all("passwall2",id)
                if cfg and cfg[".type"]=="nodes" and not is_special_protocol(cfg.protocol or "") then
                    target[id]=true; ordered[#ordered+1]=id
                end
            end
        end
        if #ordered==0 then write_json({ok=false,error="NO_VALID_NODES"}); return end

        local sys=require "luci.sys"
        local stamp=tostring(os.time()).."-"..tostring(math.random(1000,9999))
        local bpw="/tmp/passwall2-before-fastacl24-delete-"..stamp
        local bjfa="/tmp/juliang-fastacl-before-fastacl24-delete-"..stamp
        if sys.call("cp -af /etc/config/passwall2 "..util.shellquote(bpw))~=0 or
           sys.call("cp -af /etc/config/juliang_fastacl "..util.shellquote(bjfa))~=0 then
            write_json({ok=false,error="BACKUP_FAILED"}); return
        end

        local assigned={}
        for _,a in ipairs(aps) do assigned[a.ap]=uci:get("juliang_fastacl",a.section,"node") or "" end

        local function rollback(reason,detail)
            sys.call("cp -af "..util.shellquote(bpw).." /etc/config/passwall2")
            sys.call("cp -af "..util.shellquote(bjfa).." /etc/config/juliang_fastacl")
            sys.call("/usr/bin/juliang-fastacl repair >/tmp/juliang-fastacl/v24-delete-rollback.log 2>&1")
            write_json({ok=false,error=reason,detail=detail or "",rolled_back=true})
        end

        local cleared={}
        for _,a in ipairs(aps) do
            if target[assigned[a.ap] or ""] then
                local rr=exec_json("/usr/bin/juliang-fastacl clear "..a.ap)
                if not rr.ok then rollback("CLEAR_ASSIGNED_FAILED",rr); return end
                cleared[#cleared+1]=a.ap
            end
        end

        local dependent={}
        local all=uci:get_all("passwall2") or {}
        for sid,sec in pairs(all) do
            if type(sec)=="table" and not target[sid] then
                if target[sec.preproxy_node or ""] then
                    uci:delete("passwall2",sid,"preproxy_node")
                    uci:delete("passwall2",sid,"chain_proxy")
                    dependent[sid]=true
                end
                for k,v in pairs(sec) do
                    if type(k)=="string" and k:sub(1,1)~="." and k~="preproxy_node" and k~="chain_proxy" then
                        if type(v)=="string" and target[v] then
                            uci:delete("passwall2",sid,k)
                        elseif type(v)=="table" then
                            local keep,changed={},false
                            for _,item in ipairs(v) do if target[item] then changed=true else keep[#keep+1]=item end end
                            if changed then
                                if #keep>0 then uci:set_list("passwall2",sid,k,keep) else uci:delete("passwall2",sid,k) end
                            end
                        end
                    end
                end
            end
        end

        for _,id in ipairs(ordered) do uci:delete("passwall2",id) end
        if not uci:commit("passwall2") then rollback("PASSWALL2_COMMIT_FAILED"); return end

        local rebuilt={}
        for _,a in ipairs(aps) do
            local dep=assigned[a.ap] or ""
            if dep~="" and not target[dep] and dependent[dep] then
                local rr=exec_json("/usr/bin/juliang-fastacl switch "..a.ap.." "..util.shellquote(dep))
                if not rr.ok then rollback("DEPENDENT_REBUILD_FAILED",rr); return end
                rebuilt[#rebuilt+1]=a.ap
            end
        end

        sys.call("/usr/bin/juliang-fastacl save-state >/dev/null 2>&1")
        write_json({ok=true,action="delete_nodes",deleted=ordered,deleted_count=#ordered,cleared=cleared,rebuilt=rebuilt}); return
    end

]=]
assign=s:find('    if action == "assign" then',1,true); assert(assign)
s=s:sub(1,assign-1)..block..s:sub(assign)
local o=assert(io.open(path,'wb')); o:write(s); o:close()
LUA

lua -e "assert(loadfile('$CTRL'))" || { echo '[ERROR] controller syntax failed, rolling back' >&2; cp -af "$BACKUP/controller.lua" "$CTRL"; exit 1; }

grep -q 'FastACL 2.4 node admin backend fix1' "$CTRL" || { echo '[ERROR] backend marker missing' >&2; exit 1; }

JFA_VIEW="$VIEW" lua <<'LUA'
local path=assert(os.getenv('JFA_VIEW'))
local f=assert(io.open(path,'rb')); local s=f:read('*a'); f:close()
local old=s:find('<!-- JuLiangTK FastACL 2.4 node manager UI -->',1,true)
if old then
    local foot=s:find('<%+footer%>',old,true)
    if foot then s=s:sub(1,old-1)..s:sub(foot) end
end
s=s:gsub('<script type="text/javascript" src="/luci%-static/resources/juliang%-fastacl%-v24%.js[^>]*></script>%s*','')
local foot=assert(s:find('<%+footer%>',1,true),'footer missing')
local inc='<script type="text/javascript" src="/luci-static/resources/juliang-fastacl-v24.js?v=2401"></script>\n'
s=s:sub(1,foot-1)..inc..s:sub(foot)
local o=assert(io.open(path,'wb')); o:write(s); o:close()
LUA

grep -q 'juliang-fastacl-v24.js?v=2401' "$VIEW" || { echo '[ERROR] JS include missing' >&2; exit 1; }
uci set juliang_fastacl.main.version='2.4.0'
uci commit juliang_fastacl
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo '[OK] FastACL 2.4 Fix1 installed'
echo '[OK] UI: rename / single delete / checkbox / batch delete'
echo '[OK] backend: assigned AP cleanup + preproxy reference cleanup'
echo "[INFO] backup: $BACKUP"
