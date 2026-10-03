module("luci.controller.fastc", package.seeall)

function index()
    local page = entry({"admin", "services", "fastc"}, template("fastc/console"), _("FastC"), 27)
    page.leaf = true
    page.dependent = false
    page.acl_depends = { "fastc" }

    local api = entry({"admin", "services", "fastc_api"}, call("handle"), nil)
    api.leaf = true
    api.dependent = false
    api.acl_depends = { "fastc" }
end

local function write_json(t)
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    http.prepare_content("application/json")
    http.write(jsonc.stringify(t))
end

local function read_json(path, fallback)
    local f = io.open(path, "rb")
    if not f then return fallback end
    local raw = f:read("*a") or ""
    f:close()
    local ok, obj = pcall(require("luci.jsonc").parse, raw)
    if ok and type(obj) == "table" then return obj end
    return fallback
end

local function write_file(path, data, mode)
    local f = io.open(path, mode or "wb")
    if not f then return false end
    f:write(data or "")
    f:close()
    return true
end

local function shell_quote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function core_info()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    local path = trim(sys.exec("command -v mihomo 2>/dev/null") or "")
    if path == "" then path = trim(sys.exec("command -v clash 2>/dev/null") or "") end
    if path == "" and fs.access("/etc/openclash/core/clash_meta", "x") then path = "/etc/openclash/core/clash_meta" end
    if path == "" and fs.access("/etc/openclash/core/clash", "x") then path = "/etc/openclash/core/clash" end
    if path == "" and fs.access("/usr/bin/clash_meta", "x") then path = "/usr/bin/clash_meta" end

    local running = sys.call("pidof mihomo clash clash_meta >/dev/null 2>&1 || pgrep -f '/etc/openclash/core/clash_meta' >/dev/null 2>&1") == 0
    return {
        present = path ~= "",
        path = path,
        running = running
    }
end

local function fastacl_info(uci)
    local sys = require "luci.sys"
    local enabled = uci:get("juliang_fastacl", "main", "enabled") == "1"
    local guardian = sys.call("pgrep -f '/usr/bin/juliang-fastacl-guard' >/dev/null 2>&1") == 0
    local table_ok = sys.call("nft list table inet juliang_fastacl >/dev/null 2>&1") == 0
    return {
        installed = sys.call("test -x /usr/bin/juliang-fastacl") == 0,
        enabled = enabled,
        running = guardian or table_ok
    }
end

local function fastc_config(uci)
    return {
        version = uci:get("fastc", "main", "version") or "0.1.1-dev",
        enabled = uci:get("fastc", "main", "enabled") == "1",
        mode = uci:get("fastc", "main", "mode") or "fastacl",
        core = uci:get("fastc", "main", "core") or "mihomo",
        controller = uci:get("fastc", "main", "controller") or "127.0.0.1:9097",
        tproxy_port = tonumber(uci:get("fastc", "main", "tproxy_port") or "7895") or 7895,
        dns_port = tonumber(uci:get("fastc", "main", "dns_port") or "1053") or 1053
    }
end

function handle()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local jsonc = require "luci.jsonc"
    local uci = require("uci").cursor()
    local action = http.formvalue("action") or "status"

    if action == "status" then
        local nodes = read_json("/etc/fastc/nodes.json", {})
        local core = core_info()
        write_json({
            ok = true,
            config = fastc_config(uci),
            core_present = core.present,
            core_path = core.path,
            core_running = core.running,
            fastacl = fastacl_info(uci),
            nodes = nodes,
            node_count = #nodes
        })
        return
    end

    if action == "import" then
        local chunk = http.formvalue("chunk") or ""
        local chunk_index = tonumber(http.formvalue("chunk_index") or "")
        local total_chunks = tonumber(http.formvalue("total_chunks") or "")
        if not chunk_index or not total_chunks or chunk_index < 0 or total_chunks < 1 or total_chunks > 64 or chunk_index >= total_chunks then
            write_json({ok=false,error="BAD_IMPORT_CHUNK"})
            return
        end
        if #chunk > 65536 then
            write_json({ok=false,error="CHUNK_TOO_LARGE"})
            return
        end

        local tmp = "/tmp/fastc-import.links"
        local mode = (chunk_index == 0) and "wb" or "ab"
        if not write_file(tmp, chunk, mode) then
            write_json({ok=false,error="IMPORT_OPEN_FAILED"})
            return
        end

        if chunk_index + 1 < total_chunks then
            write_json({ok=true,chunk=chunk_index+1,total=total_chunks,finished=false})
            return
        end

        local raw = sys.exec("lua /usr/libexec/fastc-import.lua " .. shell_quote(tmp) .. " 2>/tmp/fastc-import.log") or ""
        local ok, result = pcall(jsonc.parse, raw)
        if not ok or type(result) ~= "table" or result.ok ~= true then
            local detail = sys.exec("cat /tmp/fastc-import.log 2>/dev/null") or ""
            if detail == "" then detail = raw end
            write_json({ok=false,error="IMPORT_FAILED",detail=detail})
            return
        end
        result.finished = true
        write_json(result)
        return
    end

    if action == "delete" then
        local id = http.formvalue("id") or ""
        if not id:match("^n%d+$") then
            write_json({ok=false,error="BAD_NODE"})
            return
        end
        local nodes = read_json("/etc/fastc/nodes.json", {})
        local out, removed = {}, false
        for _, n in ipairs(nodes) do
            if n.id == id then removed = true else out[#out+1] = n end
        end
        if not removed then
            write_json({ok=false,error="NODE_NOT_FOUND"})
            return
        end
        sys.call("mkdir -p /etc/fastc")
        local f = io.open("/etc/fastc/nodes.json", "wb")
        if not f then
            write_json({ok=false,error="WRITE_FAILED"})
            return
        end
        f:write(jsonc.stringify(out, true))
        f:close()
        write_json({ok=true,id=id,total=#out})
        return
    end

    write_json({ok=false,error="BAD_ACTION"})
end
