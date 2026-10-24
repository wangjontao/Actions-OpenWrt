local sys=require 'luci.sys'
local m=Map('juliang_bbr',translate('BBR TCP 加速'),translate('作用于路由器新建的 TCP 连接，包括固定入口的 TCP 出站连接。不会直接加速 UDP，也不会改变 DNS、代理出口或现有队列整形。已建立的 TCP 连接需重新建立后生效。'))
local s=m:section(NamedSection,'main','main',translate('设置'))
s.addremove=false
local f=s:option(Flag,'enabled',translate('启用 BBR'))
f.rmempty=false
f.default='1'
function f.validate(self,value)
 if value=='1' and sys.call('/usr/libexec/juliang-bbr available >/dev/null 2>&1')~=0 then
  return nil,translate('当前内核缺少匹配的 BBR 模块，未能启用。请安装适配模块或升级固件。')
 end
 return value
end
local state=s:option(DummyValue,'_current',translate('当前 TCP 算法'))
function state.cfgvalue() return (sys.exec('sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null'):gsub('%s+$','')) end
function m.on_after_commit(self)
 if sys.call('/usr/libexec/juliang-bbr apply >/tmp/juliang-bbr.log 2>&1')~=0 then
  self.message=translate('应用失败，请查看 /tmp/juliang-bbr.log；以当前 TCP 算法为准。')
 end
end
return m
