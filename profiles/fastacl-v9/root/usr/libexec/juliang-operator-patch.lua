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
    local s = read(path)
    if not s then return false, "quickstart controller missing" end
    if s:find("JULIANG_OPERATOR_V234", 1, true) then return true end
    backup(path)

    s = s:gsub(
        'entry%(%{"admin", "quickstart"%}, template%("quickstart/home"%), _%("QuickStart"%), 1%)%.leaf = true',
        'local jfa_home = entry({"admin", "quickstart"}, template("quickstart/home"), _("QuickStart"), 1)\n        jfa_home.leaf = true\n        jfa_home.acl_depends = { "juliang-operator-home" }',
        1
    )

    local admin_paths = {
        '{"admin", "network_guide"}',
        '{"admin", "quickwifi"}',
        '{"admin", "nas", "raid"}',
        '{"admin", "nas", "smart"}',
        '{"admin", "network", "interfaceconfig"}'
    }

    -- Add a helper once, then wrap the selected configuration entries.
    local marker = [[
-- JULIANG_OPERATOR_V234
local function jfa_admin_only(e)
    e.acl_depends = { "juliang-quickstart-admin" }
    return e
end
]]
    s = s:gsub('module%("luci%.controller%.quickstart", package%.seeall%)%s*', '%0\n' .. marker .. '\n', 1)

    for _, p in ipairs(admin_paths) do
        local esc = p:gsub("([^%w])", "%%%1")
        s = s:gsub('entry%(' .. esc .. '([^\n]-)%)', 'jfa_admin_only(entry(' .. p .. '%1))', 1)
    end

    write(path, s)
    return true
end

local function patch_quickstart_template()
    local path = "/usr/lib/lua/luci/view/quickstart/main.htm"
    local s = read(path)
    if not s then return false, "quickstart template missing" end
    if s:find("JULIANG_OPERATOR_HOME_V234", 1, true) then return true end
    backup(path)

    local old = '  local uci = require "luci.model.uci".cursor()'
    local new = old .. [[
  local op_user = uci:get("juliang_operator", "main", "username") or ""
  local auth_user = (luci.dispatcher.context and luci.dispatcher.context.authuser) or ""
  local operator_mode = (op_user ~= "" and auth_user == op_user)
]]
    s = replace_once(s, old, new)

    local needle = '      window.quickstart_configs = <%=jsonc.stringify(configs)%>;'
    local inject = needle .. [[

      // JULIANG_OPERATOR_HOME_V234
      window.juliang_operator_mode = <%=operator_mode and "true" or "false"%>;
      if (window.juliang_operator_mode) {
        const __jfaFetch = window.fetch.bind(window);
        window.fetch = function(input, init) {
          try {
            const u = (typeof input === 'string') ? input : (input && input.url) || '';
            const method = String((init && init.method) || 'GET').toUpperCase();
            if (method === 'GET' && /\/cgi-bin\/luci\/istore\/system\/module-settings\/?(?:\?|$)/.test(u)) {
              const body = JSON.stringify({
                success: 0,
                result: {
                  diableDisplay: [ "diskInfo", "storage", "downloadService", "remoteDomain" ]
                }
              });
              return Promise.resolve(new Response(body, {
                status: 200,
                headers: { "Content-Type": "application/json" }
              }));
            }
          } catch (e) {}
          return __jfaFetch(input, init);
        };
      }
]]
    s = replace_once(s, needle, inject)

    local app = '<div id="app">\n</div>'
    local operator_ui = app .. [[
<% if operator_mode then %>
<style>
/* Operator home is display-only. Keep status modules, hide sensitive cards/actions. */
#app .model_btn,
#app .settings-wrapper,
#app .item1.bgcolor1,
#app .item1.bgcolor2 {
  display: none !important;
}
#app .card-container {
  pointer-events: none !important;
}
</style>
<script>
(function(){
  function jfaOperatorTrim(){
    document.querySelectorAll('#app .model_btn,#app .settings-wrapper,#app .item1.bgcolor1,#app .item1.bgcolor2')
      .forEach(function(el){ el.style.setProperty('display','none','important'); });
  }
  new MutationObserver(jfaOperatorTrim).observe(document.getElementById('app'), {childList:true,subtree:true});
  jfaOperatorTrim();
})();
</script>
<% end %>
]]
    s = replace_once(s, app, operator_ui)
    write(path, s)
    return true
end

local function patch_istore_backend()
    local path = "/usr/lib/lua/luci/controller/istore_backend.lua"
    local s = read(path)
    if not s then return false, "istore backend missing" end
    if s:find("JULIANG_OPERATOR_ISTORE_V234", 1, true) then return true end
    backup(path)

    local needle = "  local sid, sdat = get_session()"
    local inject = needle .. [[

  -- JULIANG_OPERATOR_ISTORE_V234
  -- The restricted operator may view iStore home data but cannot mutate iStore.
  if sdat ~= nil then
    local uci = require "luci.model.uci".cursor()
    local op_user = uci:get("juliang_operator", "main", "username") or ""
    if op_user ~= "" and sdat.username == op_user then
      local method = http.getenv("REQUEST_METHOD") or "GET"
      if method ~= "GET" then
        http.status(403, "Operator is read-only")
        sock:close()
        return
      end
    end
  end
]]
    local changed
    s, changed = replace_once(s, needle, inject)
    if not changed then return false, "istore backend patch anchor missing" end
    write(path, s)
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
    {"istore-backend", patch_istore_backend},
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
