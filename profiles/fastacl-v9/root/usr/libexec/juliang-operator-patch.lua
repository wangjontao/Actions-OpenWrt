local fs = require "nixio.fs"

local function read(path)
    return fs.readfile(path)
end

local function write(path, data)
    local tmp = path .. ".jfa.tmp"
    assert(fs.writefile(tmp, data))
    assert(fs.rename(tmp, path))
end

local function backup(path)
    local bak = path .. ".juliang-operator.bak"
    if fs.access(path) and not fs.access(bak) then
        assert(fs.copy(path, bak))
    end
end

local function replace_once(s, old, new)
    local i, j = s:find(old, 1, true)
    if not i then return s, false end
    return s:sub(1, i - 1) .. new .. s:sub(j + 1), true
end

local function patch_quickstart_controller()
    local path = "/usr/lib/lua/luci/controller/quickstart.lua"
    local bak = path .. ".juliang-operator.bak"

    -- Always start from the original QuickStart controller if the previous
    -- Operator build patched it. This makes 2.3.5 deterministic on upgrades.
    if fs.access(bak) then
        assert(fs.copy(bak, path))
    end

    local s = read(path)
    if not s then return false, "quickstart controller missing" end
    backup(path)

    local old = '        entry({"admin", "quickstart"}, template("quickstart/home"), _("QuickStart"), 1).leaf = true'
    local new = '        local jfa_home = entry({"admin", "quickstart"}, call("juliang_operator_home"), _("首页"), 1)\n' ..
                '        jfa_home.leaf = true\n' ..
                '        jfa_home.acl_depends = { "juliang-operator-home" }'
    local changed
    s, changed = replace_once(s, old, new)
    if not changed then return false, "quickstart home anchor missing" end

    local fn = [[

-- JULIANG_OPERATOR_HOME_V235
function juliang_operator_home()
    local dispatcher = require "luci.dispatcher"
    local template = require "luci.template"
    local uci = require "luci.model.uci".cursor()
    local op_user = uci:get("juliang_operator", "main", "username") or ""
    local auth_user = (dispatcher.context and dispatcher.context.authuser) or ""

    if op_user ~= "" and auth_user == op_user then
        template.render("juliang_operator/home")
    else
        template.render("quickstart/home")
    end
end
]]
    s = s:gsub('module%("luci%.controller%.quickstart", package%.seeall%)',
        'module("luci.controller.quickstart", package.seeall)' .. fn, 1)

    local entries = {
        {
            '        entry({"admin", "network_guide"}, call("networkguide_index"), _("NetworkGuide"), 2)',
            '        local jfa_network_guide = entry({"admin", "network_guide"}, call("networkguide_index"), _("NetworkGuide"), 2)\n' ..
            '        jfa_network_guide.acl_depends = { "juliang-quickstart-admin" }'
        },
        {
            '            entry({"admin", "quickwifi"}, call("quickwifi_index"), _("Wireless"), 3)',
            '            local jfa_quickwifi = entry({"admin", "quickwifi"}, call("quickwifi_index"), _("Wireless"), 3)\n' ..
            '            jfa_quickwifi.acl_depends = { "juliang-quickstart-admin" }'
        },
        {
            '        entry({"admin", "nas", "raid"}, call("quickstart_index", {index={"admin", "nas"}}), _("RAID"), 10).leaf = true',
            '        local jfa_raid = entry({"admin", "nas", "raid"}, call("quickstart_index", {index={"admin", "nas"}}), _("RAID"), 10)\n' ..
            '        jfa_raid.leaf = true\n' ..
            '        jfa_raid.acl_depends = { "juliang-quickstart-admin" }'
        },
        {
            '        entry({"admin", "nas", "smart"}, call("quickstart_index", {index={"admin", "nas"}}), _("S.M.A.R.T."), 11).leaf = true',
            '        local jfa_smart = entry({"admin", "nas", "smart"}, call("quickstart_index", {index={"admin", "nas"}}), _("S.M.A.R.T."), 11)\n' ..
            '        jfa_smart.leaf = true\n' ..
            '        jfa_smart.acl_depends = { "juliang-quickstart-admin" }'
        },
        {
            '        entry({"admin", "network", "interfaceconfig"}, call("quickstart_index", {index={"admin", "network"}}), _("NetworkPort"), 11).leaf = true',
            '        local jfa_port = entry({"admin", "network", "interfaceconfig"}, call("quickstart_index", {index={"admin", "network"}}), _("NetworkPort"), 11)\n' ..
            '        jfa_port.leaf = true\n' ..
            '        jfa_port.acl_depends = { "juliang-quickstart-admin" }'
        }
    }

    for _, pair in ipairs(entries) do
        local did
        s, did = replace_once(s, pair[1], pair[2])
        if not did then return false, "quickstart admin route anchor missing" end
    end

    write(path, s)
    return true
end

local function patch_quickstart_template()
    local path = "/usr/lib/lua/luci/view/quickstart/main.htm"
    local bak = path .. ".juliang-operator.bak"
    local s = read(path)
    if not s then return true end

    -- Operator 2.3.5 no longer loads the iStore/QuickStart SPA for restricted
    -- users. Restore the original template so root keeps the stock homepage.
    if s:find("JULIANG_OPERATOR_HOME_V234", 1, true) and fs.access(bak) then
        assert(fs.copy(bak, path))
    end
    return true
end

local function patch_istore_backend()
    local path = "/usr/lib/lua/luci/controller/istore_backend.lua"
    local bak = path .. ".juliang-operator.bak"
    local s = read(path)
    if not s then return true end

    -- Fix1: the earlier operator build rejected every POST from iStore backend.
    -- QuickStart legitimately uses POST for some read/status calls, which LuCI
    -- surfaced as "session expired". Restore the original backend and enforce
    -- restrictions at the menu/page layer instead.
    if s:find("JULIANG_OPERATOR_ISTORE_V234", 1, true) then
        if fs.access(bak) then
            assert(fs.copy(bak, path))
            return true
        end

        local a = s:find("  %-%- JULIANG_OPERATOR_ISTORE_V234", 1)
        local b = s:find("  local num = tonumber%(", a or 1)
        if a and b then
            s = s:sub(1, a - 1) .. s:sub(b)
            write(path, s)
            return true
        end
        return false, "cannot remove old iStore POST guard"
    end

    return true
end

local function patch_istore_routes()
    local targets = {
        {
            path = "/usr/lib/lua/luci/controller/istorex.lua",
            old = '        entry({"admin", "istorex"}, call("istorex_template")).leaf = true',
            new = '        local jfa_istorex = entry({"admin", "istorex"}, call("istorex_template"))\n' ..
                  '        jfa_istorex.leaf = true\n' ..
                  '        jfa_istorex.acl_depends = { "juliang-quickstart-admin" }'
        },
        {
            path = "/usr/lib/lua/luci/controller/istorerouter.lua",
            old = '        entry({"admin", "istorerouter"}, call("istorerouter_template")).leaf = true',
            new = '        local jfa_istorerouter = entry({"admin", "istorerouter"}, call("istorerouter_template"))\n' ..
                  '        jfa_istorerouter.leaf = true\n' ..
                  '        jfa_istorerouter.acl_depends = { "juliang-quickstart-admin" }'
        }
    }

    for _, t in ipairs(targets) do
        local s = read(t.path)
        if s and not s:find("juliang%-quickstart%-admin", 1) then
            backup(t.path)
            local changed
            s, changed = replace_once(s, t.old, t.new)
            if changed then
                write(t.path, s)
            end
        end
    end
    return true
end

local function patch_blank_login_user()
    local p = io.popen([[find /usr/share/ucode/luci/template /usr/lib/lua/luci/view -type f \( -name 'sysauth.ut' -o -name 'sysauth.htm' \) 2>/dev/null]])
    if not p then return true end
    for path in p:lines() do
        local s = read(path)
        if s then
            local orig = s
            s = s:gsub('value="{{ entityencode%(duser, true%) }}"', 'value=""')
            s = s:gsub('value="<%%=.-duser.-%%>"', 'value=""')
            s = s:gsub("value='<%%=.-duser.-%%>'", "value=''")
            if s ~= orig then
                backup(path)
                write(path, s)
            end
        end
    end
    p:close()
    return true
end

local function patch_wireless_menu()
    local path = "/usr/share/luci/menu.d/luci-mod-network.json"
    local s = read(path)
    if not s then return false, "luci-mod-network menu missing" end
    if s:find('"juliang-wireless-operator"', 1, true) then return true end
    backup(path)

    local p = s:find('"admin/network/wireless"', 1, true)
    if not p then return false, "wireless menu anchor missing" end
    local a, b = s:find('"acl"%s*:%s*%[%s*"luci%-mod%-network%-config"%s*%]', p)
    if not a then return false, "wireless ACL anchor missing" end
    s = s:sub(1, a - 1) .. '"acl": [ "juliang-wireless-operator" ]' .. s:sub(b + 1)
    write(path, s)
    return true
end

local checks = {
    {"quickstart-controller", patch_quickstart_controller},
    {"quickstart-template", patch_quickstart_template},
    {"istore-backend-restore", patch_istore_backend},
    {"istore-routes", patch_istore_routes},
    {"blank-login-user", patch_blank_login_user},
    {"wireless-menu", patch_wireless_menu}
}

local failed = false
for _, item in ipairs(checks) do
    local ok, err = item[2]()
    if ok then
        io.stdout:write("[OK] " .. item[1] .. "\n")
    else
        failed = true
        io.stderr:write("[ERROR] " .. item[1] .. ": " .. tostring(err) .. "\n")
    end
end

os.exit(failed and 1 or 0)
