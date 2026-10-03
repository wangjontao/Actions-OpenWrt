module("luci.controller.juliang_fastacl_mode", package.seeall)

function index()
    local e = entry({"admin", "services", "juliang_fastacl_mode"}, call("handle"), nil)
    e.leaf = true
    e.dependent = false
    e.acl_depends = { "juliang-fastacl-operator" }
end

local function write_json(t)
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    http.prepare_content("application/json")
    http.write(jsonc.stringify(t))
end

local function is_special_protocol(p)
    return p == "_shunt" or p == "_balancing" or p == "_urltest" or p == "_iface"
end

local function guardian_running()
    local sys = require "luci.sys"
    if sys.call("/etc/init.d/juliang-fastacl running >/dev/null 2>&1") == 0 then return true end
    if sys.call("ps w 2>/dev/null | grep '[j]uliang-fastacl-guard' >/dev/null 2>&1") == 0 then return true end
    return false
end

local function exec_json(cmd)
    local sys = require "luci.sys"
    local jsonc = require "luci.jsonc"
    local raw = sys.exec(cmd .. " 2>/tmp/juliang-fastacl/mode-api-error.log")
    local ok, data = pcall(jsonc.parse, raw or "")
    if ok and type(data) == "table" then return data end
    return { ok = false, error = "ENGINE_ERROR", detail = raw or "" }
end

function handle()
    local http = require "luci.http"
    local util = require "luci.util"
    local uci = require("uci").cursor()
    local action = http.formvalue("action") or "status"

    if action == "status" then
        local aps = {}
        uci:foreach("juliang_fastacl", "ap", function(s)
            local n = tonumber(s.slot or (s[".name"] or ""):match("^ap(%d+)$"))
            if n then
                local node = s.node or ""
                local mode = s.mode or ""
                if node ~= "" then mode = "proxy"
                elseif mode == "" then mode = (s.network == "lan") and "direct_cn" or "proxy" end
                aps[#aps + 1] = {
                    ap = "AP" .. n,
                    slot = n,
                    ssid = s.ssid or ("AP" .. n),
                    network = s.network or "",
                    subnet = s.subnet or "",
                    mode = mode,
                    node = node
                }
            end
        end)
        table.sort(aps, function(a,b) return a.slot < b.slot end)

        local nodes = {}
        uci:foreach("passwall2", "nodes", function(s)
            local id = s[".name"] or ""
            local proto = s.protocol or ""
            if id ~= "" and not is_special_protocol(proto) then
                nodes[#nodes + 1] = {
                    id = id,
                    remarks = s.remarks or id,
                    type = s.type or "",
                    protocol = proto
                }
            end
        end)
        table.sort(nodes, function(a,b) return (a.remarks or "") < (b.remarks or "") end)

        write_json({ ok=true, guardian=guardian_running(), aps=aps, nodes=nodes })
        return
    end

    if action == "set_mode" then
        local ap = http.formvalue("ap") or ""
        local mode = http.formvalue("mode") or ""
        local node = http.formvalue("node") or ""
        if not ap:match("^AP%d+$") then write_json({ok=false,error="BAD_AP"}); return end
        if mode ~= "proxy" and mode ~= "direct_cn" then write_json({ok=false,error="BAD_MODE"}); return end
        local cmd = "/usr/bin/juliang-fastacl-mode set " .. util.shellquote(ap) .. " " .. util.shellquote(mode)
        if mode == "proxy" then cmd = cmd .. " " .. util.shellquote(node) end
        write_json(exec_json(cmd))
        return
    end

    if action == "guardian_restart" then
        local rc = require("luci.sys").call("/etc/init.d/juliang-fastacl restart >/tmp/juliang-fastacl/guardian-restart.log 2>&1")
        write_json({ok=(rc==0), guardian=guardian_running()})
        return
    end

    write_json({ok=false,error="BAD_ACTION"})
end
