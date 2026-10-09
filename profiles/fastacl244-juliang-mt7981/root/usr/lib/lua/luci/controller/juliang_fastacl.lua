module("luci.controller.juliang_fastacl", package.seeall)

function index()
    local api = entry({"admin", "services", "juliang_fastacl"}, call("handle"), nil)
    api.leaf = true
    api.dependent = false
    api.acl_depends = { "juliang-fastacl-operator" }

    local console = entry({"admin", "services", "juliang_fastacl_console"}, template("juliang_fastacl/console"), _("FastACL 控制台"), 26)
    console.leaf = true
    console.dependent = false
    console.acl_depends = { "juliang-fastacl-operator" }
end

local function write_json(t)
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    http.prepare_content("application/json")
    http.write(jsonc.stringify(t))
end

local function ap_sections(uci)
    local out = {}
    uci:foreach("juliang_fastacl", "ap", function(s)
        local n = tonumber(s.slot or (s[".name"] or ""):match("^ap(%d+)$"))
        if n then
            out[#out + 1] = {
                n = n,
                ap = "AP" .. n,
                section = s[".name"] or ("ap" .. n),
                ssid = s.ssid or ("AP" .. n),
                network = s.network or "",
                subnet = s.subnet or "",
                router_ip = s.router_ip or "",
                socks_port = tonumber(s.socks_port or "") or (13100 + n),
                preproxy_port = tonumber(s.preproxy_port or "") or (14100 + n),
                node = s.node or ""
            }
        end
    end)
    table.sort(out, function(a,b) return a.n < b.n end)
    return out
end

local function ap_number(uci, v)
    local n = tonumber((v or ""):match("^AP(%d+)$"))
    if not n or n < 1 then return nil end
    if uci:get("juliang_fastacl", "ap" .. n) ~= "ap" then return nil end
    return n
end

local function read_ip(n)
    local f = io.open("/tmp/juliang-fastacl/ap" .. n .. ".ip", "r")
    if not f then return "" end
    local ip = (f:read("*l") or ""):gsub("%s+", "")
    f:close()
    return ip
end

local function runtime_status()
    local f = io.open("/tmp/juliang-fastacl/router.pid", "r")
    if not f then return "stopped" end
    local pid = tonumber(f:read("*l") or "")
    f:close()
    if not pid then return "stopped" end
    local sys = require "luci.sys"
    if sys.call("kill -0 " .. pid .. " >/dev/null 2>&1") ~= 0 then return "stopped" end
    local port = tonumber(require("uci").cursor():get("juliang_fastacl", "main", "tproxy_port") or "12345")
    local cmd = "(ss -lnt 2>/dev/null; ss -lnu 2>/dev/null; netstat -lnt 2>/dev/null; netstat -lnu 2>/dev/null) | grep -q ':" .. port .. " '"
    local listener = sys.call(cmd) == 0
    local nft = sys.call("nft list table inet juliang_fastacl >/dev/null 2>&1") == 0
    local rule = sys.call("ip rule show 2>/dev/null | grep -q 'fwmark 0x66/0xff.*lookup 100'") == 0
    return (listener and nft and rule) and "running" or "broken"
end

local function exec_json(cmd)
    local sys = require "luci.sys"
    local jsonc = require "luci.jsonc"
    local raw = sys.exec(cmd .. " 2>/tmp/juliang-fastacl/luci-error.log")
    local ok, data = pcall(jsonc.parse, raw or "")
    if ok and type(data) == "table" then return data end
    return { ok = false, error = "ENGINE_ERROR", detail = raw or "" }
end

local function is_special_protocol(p)
    return p == "_shunt" or p == "_balancing" or p == "_urltest" or p == "_iface"
end

local function preproxy_options(uci, current)
    local out = {}
    uci:foreach("passwall2", "nodes", function(s)
        local id = s[".name"] or ""
        local proto = s.protocol or ""
        local chained = s.chain_proxy or ""
        if id ~= "" and id ~= current and not is_special_protocol(proto) and chained == "" then
            out[#out + 1] = {
                id = id,
                remarks = s.remarks or id,
                type = s.type or "",
                protocol = proto
            }
        end
    end)
    table.sort(out, function(a,b) return (a.remarks or "") < (b.remarks or "") end)
    return out
end

function handle()
    local http = require "luci.http"
    local util = require "luci.util"
    local uci = require("uci").cursor()
    local action = http.formvalue("action") or "status"
    local aps = ap_sections(uci)

    if action == "import" then
        local chunk = http.formvalue("chunk")
        local chunk_index = tonumber(http.formvalue("chunk_index"))
        local total_chunks = tonumber(http.formvalue("total_chunks"))
        local group = http.formvalue("group") or "default"

        if not chunk or chunk_index == nil or total_chunks == nil or chunk_index < 0 or total_chunks < 1 or chunk_index >= total_chunks then
            write_json({ok=false,error="BAD_IMPORT_CHUNK"})
            return
        end

        -- Keep this endpoint deliberately narrow: it mirrors PassWall2's
        -- existing link importer without exposing the PassWall2 UI/API.
        local tmp_file = "/tmp/links.conf"
        local mode = (chunk_index == 0) and "w" or "a"
        local fh = io.open(tmp_file, mode)
        if not fh then
            write_json({ok=false,error="IMPORT_OPEN_FAILED"})
            return
        end
        fh:write(chunk)
        fh:close()

        if chunk_index + 1 == total_chunks then
            local rc = require("luci.sys").call("lua /usr/share/passwall2/subscribe.lua add " .. util.shellquote(group) .. " >/tmp/juliang-fastacl/import.log 2>&1")
            if rc ~= 0 then
                write_json({ok=false,error="IMPORT_FAILED"})
                return
            end
        end

        write_json({ok=true,chunk=chunk_index+1,total=total_chunks,finished=(chunk_index+1==total_chunks)})
        return
    end

    if action == "status" then
        local map, ap_to_node, ips, labels = {}, {}, {}, {}
        local ap_meta = {}

        for _, a in ipairs(aps) do
            local node = uci:get("juliang_fastacl", a.section, "node") or ""
            ap_to_node[a.ap] = node
            ips[a.ap] = read_ip(a.n)
            labels[a.ap] = a.ssid
            ap_meta[#ap_meta + 1] = {
                ap = a.ap,
                slot = a.n,
                ssid = a.ssid,
                network = a.network,
                subnet = a.subnet,
                router_ip = a.router_ip,
                socks_port = a.socks_port
            }
            if node ~= "" then
                map[node] = map[node] or {}
                map[node][#map[node] + 1] = a.ap
            end
        end

        local preproxy = {}
        uci:foreach("passwall2", "nodes", function(s)
            local id = s[".name"] or ""
            if id ~= "" then
                local pp = s.preproxy_node or ""
                preproxy[id] = {
                    enabled = (s.chain_proxy == "1" and pp ~= ""),
                    id = pp,
                    remarks = pp ~= "" and (uci:get("passwall2", pp, "remarks") or pp) or ""
                }
            end
        end)

        local nodes = {}
        uci:foreach("passwall2", "nodes", function(s)
            local id = s[".name"] or ""
            local proto = s.protocol or ""
            if id ~= "" and not is_special_protocol(proto) then
                nodes[#nodes + 1] = {
                    id = id,
                    remarks = s.remarks or id,
                    type = s.type or "",
                    protocol = proto,
                    address = s.address or "",
                    port = tonumber(s.port or "") or 0,
                    chain_proxy = s.chain_proxy == "1",
                    preproxy_node = s.preproxy_node or "",
                    preproxy_remarks = (s.preproxy_node and s.preproxy_node ~= "") and (uci:get("passwall2", s.preproxy_node, "remarks") or s.preproxy_node) or ""
                }
            end
        end)
        table.sort(nodes, function(a,b) return (a.remarks or "") < (b.remarks or "") end)

        local sys = require "luci.sys"
        local killswitch = (sys.call("nft list table inet juliang_killswitch >/dev/null 2>&1") == 0)
        local guardian = (sys.call("pgrep -f '/usr/bin/juliang-fastacl-guard' >/dev/null 2>&1") == 0)

        write_json({
            ok = true,
            engine = runtime_status(),
            killswitch = killswitch,
            guardian = guardian,
            count = #aps,
            aps = ap_meta,
            nodes = nodes,
            map = map,
            ap_to_node = ap_to_node,
            wireless_labels = labels,
            ips = ips,
            preproxy = preproxy
        })
        return
    end

    local node = http.formvalue("node") or ""
    local node_cfg = node ~= "" and uci:get_all("passwall2", node) or nil

    -- JuLiangTK FastACL 2.4 node admin backend fix1
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

    if action == "assign" then
        local ap = http.formvalue("ap") or ""
        local n = ap_number(uci, ap)
        if not n then write_json({ok=false,error="BAD_AP"}); return end
        if not node_cfg or node_cfg[".type"] ~= "nodes" then write_json({ok=false,error="BAD_NODE"}); return end
        local exclusive = http.formvalue("exclusive") ~= "0"
        local verb = exclusive and "move" or "switch"
        write_json(exec_json("/usr/bin/juliang-fastacl " .. verb .. " " .. ap .. " " .. util.shellquote(node)))
        return
    end

    if action == "preproxy_options" then
        if not node_cfg or node_cfg[".type"] ~= "nodes" then write_json({ok=false,error="BAD_NODE"}); return end
        write_json({
            ok = true,
            current = node_cfg.preproxy_node or "",
            enabled = node_cfg.chain_proxy == "1",
            options = preproxy_options(uci, node)
        })
        return
    end

    if action == "set_preproxy" then
        if not node_cfg or node_cfg[".type"] ~= "nodes" then write_json({ok=false,error="BAD_NODE"}); return end
        local pre = http.formvalue("preproxy") or ""
        if pre == node then write_json({ok=false,error="PREPROXY_SELF"}); return end

        if pre ~= "" then
            local p = uci:get_all("passwall2", pre)
            if not p or p[".type"] ~= "nodes" or is_special_protocol(p.protocol or "") then
                write_json({ok=false,error="BAD_PREPROXY"}); return
            end
            if (p.chain_proxy or "") ~= "" then
                write_json({ok=false,error="PREPROXY_ALREADY_CHAINED"}); return
            end
        end

        local old_chain = node_cfg.chain_proxy or ""
        local old_pre = node_cfg.preproxy_node or ""
        if pre == "" then
            uci:delete("passwall2", node, "chain_proxy")
            uci:delete("passwall2", node, "preproxy_node")
        else
            uci:set("passwall2", node, "chain_proxy", "1")
            uci:set("passwall2", node, "preproxy_node", pre)
        end
        uci:commit("passwall2")

        local affected, failed = {}, nil
        for _, a in ipairs(aps) do
            if (uci:get("juliang_fastacl", a.section, "node") or "") == node then
                local rr = exec_json("/usr/bin/juliang-fastacl switch " .. a.ap .. " " .. util.shellquote(node))
                if not rr.ok then failed = rr; break end
                affected[#affected + 1] = a.ap
            end
        end

        if failed then
            if old_chain == "" then uci:delete("passwall2", node, "chain_proxy")
            else uci:set("passwall2", node, "chain_proxy", old_chain) end
            if old_pre == "" then uci:delete("passwall2", node, "preproxy_node")
            else uci:set("passwall2", node, "preproxy_node", old_pre) end
            uci:commit("passwall2")
            for _, ap in ipairs(affected) do
                exec_json("/usr/bin/juliang-fastacl switch " .. ap .. " " .. util.shellquote(node))
            end
            write_json({ok=false,error="PREPROXY_START_FAILED",detail=failed,rolled_back=true})
            return
        end

        local ip = ""
        if #affected > 0 then
            local sys = require "luci.sys"
            ip = (sys.exec("/usr/bin/juliang-fastacl probe " .. affected[1] .. " 2>/dev/null") or ""):gsub("%s+", "")
        end
        write_json({
            ok = true,
            action = "set_preproxy",
            node = node,
            preproxy = pre,
            preproxy_remarks = pre ~= "" and (uci:get("passwall2", pre, "remarks") or pre) or "",
            affected = affected,
            ip = ip
        })
        return
    end

    if action == "clear_node" then
        if not node_cfg or node_cfg[".type"] ~= "nodes" then write_json({ok=false,error="BAD_NODE"}); return end
        local cleared = {}
        for _, a in ipairs(aps) do
            if (uci:get("juliang_fastacl", a.section, "node") or "") == node then
                local rr = exec_json("/usr/bin/juliang-fastacl clear " .. a.ap)
                if rr.ok then cleared[#cleared + 1] = a.ap end
            end
        end
        write_json({ok=true,action="clear_node",node=node,cleared=cleared})
        return
    end

    if action == "probe" then
        local ap = http.formvalue("ap") or ""
        local n = ap_number(uci, ap)
        if not n then write_json({ok=false,error="BAD_AP"}); return end
        local sys = require "luci.sys"
        local ip = (sys.exec("/usr/bin/juliang-fastacl probe " .. ap .. " 2>/dev/null") or ""):gsub("%s+", "")
        write_json({ok = ip ~= "" and ip ~= "-", ap=ap, ip=ip})
        return
    end

    if action == "rediscover" then
        local rr = exec_json("/usr/bin/juliang-fastacl discover")
        write_json(rr)
        return
    end

    write_json({ok=false,error="BAD_ACTION"})
end
