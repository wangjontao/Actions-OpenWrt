-- Theme-only migration: preserve the existing LuCI authentication form and handlers.
local fs=require'nixio.fs'
local link='<link id="juliang-login-style" rel="stylesheet" href="/luci-static/argon/css/juliang-login.css?v=253-r2">'
for _,path in ipairs({'/usr/share/ucode/luci/template/themes/argon/sysauth.ut','/usr/lib/lua/luci/view/themes/argon/sysauth.htm'}) do
 local original=fs.readfile(path)
 if original then
  local text=original:gsub('class="login%-page"','class="login-page juliang-login"',1)
  text=text:gsub('<span class="brand%-text">.-</span>','<span class="brand-text">JuLiang Network Control Center</span>',1)
  if not text:find('id="juliang-login-style"',1,true) then
   text=text:gsub('(<div class="login%-page[^"]*">)',function(tag)return link..'\n'..tag end,1)
  end
  assert(text:find('id="juliang-login-style"',1,true),'Cannot locate Argon login container')
  if text~=original then
   local backup=path..'.before-juliang-login'
   if not fs.access(backup) then assert(fs.writefile(backup,original));fs.chmod(backup,'600') end
   assert(fs.writefile(path..'.juliang-new',text));fs.chmod(path..'.juliang-new','644')
   assert(fs.rename(path..'.juliang-new',path),'Cannot install centered login template')
  end
 end
end
