local M={}
local policy=require'fastacl252'
function M.save_name(u,mac,name)
  mac=assert(policy.mac(mac),'设备 MAC 无效')
  assert(type(name)=='string','设备备注名无效')
  name=name:gsub('^%s+',''):gsub('%s+$','')
  assert(#name<=80 and not name:find('[%z\1-\31\127]'),'备注名不能超过 80 字节或包含控制字符')
  local id='alias_'..mac:gsub(':','')
  if name=='' then u:delete('fastacl252',id)
  else policy.section(u,'fastacl252','device_alias',id,{mac=mac,name=name}) end
  -- Update labels only; never recreate a device section or touch its bindings.
  u:foreach('fastacl252','device',function(d)
    if policy.mac(d.mac)==mac then assert(u:set('fastacl252',d['.name'],'name',name),'保存设备备注失败') end
  end)
  return name
end
return M
