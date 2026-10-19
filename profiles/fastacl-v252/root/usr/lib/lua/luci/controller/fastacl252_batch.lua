module('luci.controller.fastacl252_batch',package.seeall)

local ACL={'juliang-fastacl252'}
local function reply(data)
  local h=require 'luci.http'
  h.prepare_content('application/json')
  h.write(require('luci.jsonc').stringify(data))
end

function index()
  if not nixio.fs.access('/etc/config/fastacl252') then return end
  local e=entry({'admin','services','fastacl252_delete_nodes'},post('delete_nodes'),nil)
  e.leaf=true; e.acl_depends=ACL
end

function delete_nodes()
  local h=require 'luci.http'; local json=require 'luci.jsonc'; local fs=require 'nixio.fs'; local policy=require 'fastacl252'
  local req=json.parse(h.formvalue('data') or '')
  local ids=type(req)=='table' and req.ids or nil
  if type(ids)~='table' or #ids<1 or #ids>256 then reply({ok=false,error='请选择 1–256 个节点'}); return end
  if not fs.mkdir('/tmp/fastacl252-edit.lock') then reply({ok=false,error='配置正在保存，请稍后重试'}); return end

  local u=require('uci').cursor(); local original=fs.readfile('/etc/config/fastacl252')
  local deleted,skipped={},{}
  local ok,err=pcall(function()
    local pending=u:changes('fastacl252'); assert(not pending or not next(pending),'请先保存配置')
    local bound={}
    local function mark(id,where)
      id=tostring(id or ''); if id=='' then return end
      bound[id]=bound[id] or {}; bound[id][#bound[id]+1]=where
    end
    u:foreach('fastacl252','device',function(d)
      mark(d.node,'设备 '..tostring(d.name or d.mac or d['.name']))
      mark(d.preproxy,'设备前置 '..tostring(d.name or d.mac or d['.name']))
    end)
    u:foreach('fastacl252','wifi',function(w)
      mark(w.node,'WiFi '..tostring(w.ssid or w['.name']))
      mark(w.preproxy,'WiFi 前置 '..tostring(w.ssid or w['.name']))
    end)

    local seen={}
    for _,id in ipairs(ids) do
      id=tostring(id or '')
      if not seen[id] then
        seen[id]=true
        if not policy.id(id) or u:get('fastacl252',id)~='node' then
          skipped[#skipped+1]={id=id,reason='节点不存在或 ID 无效'}
        elseif bound[id] then
          skipped[#skipped+1]={id=id,reason='正在使用：'..table.concat(bound[id],'、')}
        else
          u:delete('fastacl252',id); deleted[#deleted+1]=id
        end
      end
    end
    assert(u:commit('fastacl252'),'批量删除节点失败')
  end)
  if not ok then
    u:revert('fastacl252')
    if original then fs.writefile('/etc/config/fastacl252',original) end
  end
  fs.rmdir('/tmp/fastacl252-edit.lock')
  reply(ok and {ok=true,deleted=deleted,skipped=skipped,message='已删除 '..#deleted..' 个节点；跳过 '..#skipped..' 个正在使用/无效节点。'} or {ok=false,error=tostring(err)})
end
