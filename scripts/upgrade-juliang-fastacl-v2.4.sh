#!/bin/sh
set -eu

CTRL="/usr/lib/lua/luci/controller/juliang_fastacl.lua"
VIEW="/usr/lib/lua/luci/view/juliang_fastacl/console.htm"
MARK_CTRL="JuLiangTK FastACL 2.4 node admin backend"
MARK_VIEW="JuLiangTK FastACL 2.4 node manager UI"

[ -s "$CTRL" ] || { echo "[ERROR] controller not found: $CTRL" >&2; exit 1; }
[ -s "$VIEW" ] || { echo "[ERROR] console view not found: $VIEW" >&2; exit 1; }
command -v lua >/dev/null 2>&1 || { echo "[ERROR] lua not found" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/etc/juliang-fastacl/v2.4-backup-$STAMP"
mkdir -p "$BACKUP"
cp -af "$CTRL" "$BACKUP/juliang_fastacl.lua"
cp -af "$VIEW" "$BACKUP/console.htm"
cp -af /etc/config/passwall2 "$BACKUP/passwall2" 2>/dev/null || true
cp -af /etc/config/juliang_fastacl "$BACKUP/juliang_fastacl" 2>/dev/null || true

echo "=================================================="
echo " JuLiang FastACL 2.4 Upgrade"
echo " node delete / batch delete / rename"
echo "=================================================="
echo "[INFO] Backup: $BACKUP"

JFA_CTRL="$CTRL" lua <<'LUA'
local path = assert(os.getenv("JFA_CTRL"))
local f = assert(io.open(path, "rb"))
local s = f:read("*a")
f:close()

local marker = "JuLiangTK FastACL 2.4 node admin backend"
if not s:find(marker, 1, true) then
  local anchor = '    if action == "assign" then'
  local p = assert(s:find(anchor, 1, true), "FastACL controller anchor not found")
  local block = [=[
    -- JuLiangTK FastACL 2.4 node admin backend
    if action == "rename_node" then
        if not node_cfg or node_cfg[".type"] ~= "nodes" or is_special_protocol(node_cfg.protocol or "") then
            write_json({ok=false,error="BAD_NODE"})
            return
        end
        local name = (http.formvalue("name") or ""):gsub("^%s+",""):gsub("%s+$","")
        if name == "" or #name > 128 or name:find("[%z\1-\31\127]") then
            write_json({ok=false,error="BAD_NAME"})
            return
        end
        local old = node_cfg.remarks or node
        uci:set("passwall2", node, "remarks", name)
        uci:commit("passwall2")
        write_json({ok=true,action="rename_node",node=node,old_name=old,name=name})
        return
    end

    if action == "delete_nodes" then
        local raw = http.formvalue("nodes") or node or ""
        local target, ordered = {}, {}
        for id in raw:gmatch("[^,]+") do
            id = id:gsub("^%s+",""):gsub("%s+$","")
            if id ~= "" and not target[id] then
                local cfg = uci:get_all("passwall2", id)
                if cfg and cfg[".type"] == "nodes" and not is_special_protocol(cfg.protocol or "") then
                    target[id] = true
                    ordered[#ordered + 1] = id
                end
            end
        end
        if #ordered == 0 then
            write_json({ok=false,error="NO_VALID_NODES"})
            return
        end

        local sys = require "luci.sys"
        local stamp = tostring(os.time()) .. "-" .. tostring(math.random(1000,9999))
        local bpw = "/tmp/passwall2-before-fastacl24-delete-" .. stamp
        local bjfa = "/tmp/juliang-fastacl-before-fastacl24-delete-" .. stamp
        if sys.call("cp -af /etc/config/passwall2 " .. util.shellquote(bpw)) ~= 0 or
           sys.call("cp -af /etc/config/juliang_fastacl " .. util.shellquote(bjfa)) ~= 0 then
            write_json({ok=false,error="BACKUP_FAILED"})
            return
        end

        local function rollback(reason, detail)
            sys.call("cp -af " .. util.shellquote(bpw) .. " /etc/config/passwall2")
            sys.call("cp -af " .. util.shellquote(bjfa) .. " /etc/config/juliang_fastacl")
            sys.call("/usr/bin/juliang-fastacl repair >/tmp/juliang-fastacl/v24-delete-rollback.log 2>&1")
            write_json({ok=false,error=reason,detail=detail or "",rolled_back=true})
        end

        local cleared = {}
        for _, a in ipairs(aps) do
            if target[a.node or ""] then
                local rr = exec_json("/usr/bin/juliang-fastacl clear " .. a.ap)
                if not rr.ok then
                    rollback("CLEAR_ASSIGNED_FAILED", rr)
                    return
                end
                cleared[#cleared + 1] = a.ap
            end
        end

        local dependent = {}
        local all = uci:get_all("passwall2") or {}
        for sid, sec in pairs(all) do
            if type(sec) == "table" and not target[sid] then
                if target[sec.preproxy_node or ""] then
                    uci:delete("passwall2", sid, "preproxy_node")
                    uci:delete("passwall2", sid, "chain_proxy")
                    dependent[sid] = true
                end
                for k, v in pairs(sec) do
                    if type(k) == "string" and k:sub(1,1) ~= "." and k ~= "preproxy_node" and k ~= "chain_proxy" then
                        if type(v) == "string" and target[v] then
                            uci:delete("passwall2", sid, k)
                        elseif type(v) == "table" then
                            local keep, changed = {}, false
                            for _, item in ipairs(v) do
                                if target[item] then changed = true else keep[#keep + 1] = item end
                            end
                            if changed then
                                if #keep > 0 then uci:set_list("passwall2", sid, k, keep)
                                else uci:delete("passwall2", sid, k) end
                            end
                        end
                    end
                end
            end
        end

        for _, id in ipairs(ordered) do
            uci:delete("passwall2", id)
        end
        if not uci:commit("passwall2") then
            rollback("PASSWALL2_COMMIT_FAILED")
            return
        end

        local rebuilt = {}
        for dep, _ in pairs(dependent) do
            for _, a in ipairs(aps) do
                if (a.node or "") == dep then
                    local rr = exec_json("/usr/bin/juliang-fastacl switch " .. a.ap .. " " .. util.shellquote(dep))
                    if not rr.ok then
                        rollback("DEPENDENT_REBUILD_FAILED", rr)
                        return
                    end
                    rebuilt[#rebuilt + 1] = a.ap
                end
            end
        end

        sys.call("/usr/bin/juliang-fastacl save-state >/dev/null 2>&1")
        write_json({
            ok=true,
            action="delete_nodes",
            deleted=ordered,
            deleted_count=#ordered,
            cleared=cleared,
            rebuilt=rebuilt,
            backup_passwall2=bpw,
            backup_fastacl=bjfa
        })
        return
    end

]=]
  s = s:sub(1, p - 1) .. block .. s:sub(p)
end

local o = assert(io.open(path, "wb"))
o:write(s)
o:close()
LUA

lua -e "assert(loadfile('$CTRL'))" || {
  echo "[ERROR] controller syntax failed; rolling back" >&2
  cp -af "$BACKUP/juliang_fastacl.lua" "$CTRL"
  exit 1
}
grep -q "$MARK_CTRL" "$CTRL" || {
  echo "[ERROR] controller patch marker missing; rolling back" >&2
  cp -af "$BACKUP/juliang_fastacl.lua" "$CTRL"
  exit 1
}

JFA_VIEW="$VIEW" lua <<'LUA'
local path = assert(os.getenv("JFA_VIEW"))
local f = assert(io.open(path, "rb"))
local s = f:read("*a")
f:close()

local marker = "JuLiangTK FastACL 2.4 node manager UI"
if not s:find(marker, 1, true) then
  local footer = "<%+footer%>"
  local p = assert(s:find(footer, 1, true), "FastACL console footer not found")
  local extra = [=[

<!-- JuLiangTK FastACL 2.4 node manager UI -->
<style>
.jfa-v24-select{width:34px;text-align:center!important}
.jfa-v24-bulk{display:inline-flex;gap:8px;align-items:center}
.jfa-v24-count{font-size:12px;opacity:.75}
</style>
<script type="text/javascript">
(function(){
  var API24='<%=api%>', state=window.jfaState||{};
  state.selected=state.selected||{};

  function esc24(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]})}
  function apName24(ap){
    var aps=state.aps||[];
    for(var i=0;i<aps.length;i++) if(aps[i].ap===ap) return aps[i].ssid||ap;
    return ap;
  }
  function nodeAps24(id){return (state.map&&state.map[id])||[]}
  function nodeIps24(id){
    var a=nodeAps24(id), out=[];
    for(var i=0;i<a.length;i++) if(state.ips&&state.ips[a[i]]) out.push(state.ips[a[i]]);
    return out;
  }
  function updateBulk24(){
    var n=0; for(var k in state.selected) if(state.selected[k]) n++;
    var c=document.getElementById('jfa_v24_count'); if(c)c.textContent='已选 '+n+' 个';
    var b=document.getElementById('jfa_v24_delete'); if(b)b.disabled=(n===0);
    var all=document.getElementById('jfa_v24_all');
    if(all){
      var nodes=state.nodes||[], visible=0, chosen=0;
      var q=(document.getElementById('jfa_filter').value||'').toLowerCase();
      for(var i=0;i<nodes.length;i++){
        var x=nodes[i], ips=nodeIps24(x.id);
        var hay=((x.remarks||'')+' '+(x.address||'')+' '+(x.protocol||'')+' '+(x.type||'')+' '+ips.join(' ')).toLowerCase();
        if(q && hay.indexOf(q)<0) continue;
        visible++; if(state.selected[x.id]) chosen++;
      }
      all.checked=visible>0&&chosen===visible;
      all.indeterminate=chosen>0&&chosen<visible;
    }
  }

  window.toggleNodeSelection=function(id,checked){state.selected[id]=!!checked;updateBulk24()}
  window.toggleAllNodes=function(checked){
    var nodes=state.nodes||[], q=(document.getElementById('jfa_filter').value||'').toLowerCase();
    for(var i=0;i<nodes.length;i++){
      var x=nodes[i], ips=nodeIps24(x.id);
      var hay=((x.remarks||'')+' '+(x.address||'')+' '+(x.protocol||'')+' '+(x.type||'')+' '+ips.join(' ')).toLowerCase();
      if(!q || hay.indexOf(q)>=0) state.selected[x.id]=!!checked;
    }
    renderNodes();
  }

  window.renderNodes=function(){
    var q=(document.getElementById('jfa_filter').value||'').toLowerCase();
    var body=document.getElementById('jfa_body'), html='', present={};
    var nodes=state.nodes||[];
    for(var z=0;z<nodes.length;z++) present[nodes[z].id]=true;
    for(var old in state.selected) if(!present[old]) delete state.selected[old];

    for(var i=0;i<nodes.length;i++){
      var n=nodes[i], aps=nodeAps24(n.id), ips=nodeIps24(n.id), pp=(state.preproxy&&state.preproxy[n.id])||{};
      var hay=((n.remarks||'')+' '+(n.address||'')+' '+(n.protocol||'')+' '+(n.type||'')+' '+ips.join(' ')).toLowerCase();
      if(q && hay.indexOf(q)<0) continue;
      var proto=(n.type||'')+(n.protocol&&n.protocol.toLowerCase()!==(n.type||'').toLowerCase()?('/'+n.protocol):'');
      var pr=(state.probeResult&&state.probeResult[n.id])||null, probeHtml='';
      if(pr) probeHtml='<div class="jfa-probe-result '+(pr.ok?'jfa-ok':'jfa-bad')+'">'+esc24(pr.text)+(pr.time?' · '+esc24(pr.time):'')+'</div>';
      var idjs=n.id.replace(/\\/g,'\\\\').replace(/'/g,"\\'");
      html+='<tr>'+ 
        '<td class="jfa-v24-select"><input type="checkbox" '+(state.selected[n.id]?'checked="checked" ':'')+'onchange="toggleNodeSelection(\\''+idjs+'\\',this.checked)"/></td>'+ 
        '<td><strong>'+esc24(n.remarks)+'</strong><div class="jfa-small">'+esc24(n.address)+(n.port?':'+n.port:'')+'</div></td>'+ 
        '<td>'+esc24(proto)+'</td>'+ 
        '<td>'+esc24(aps.length?aps.map(apName24).join(', '):'未分配')+'</td>'+ 
        '<td class="'+(ips.length?'jfa-ok':'')+'">'+esc24(ips.length?ips.join(' / '):'-')+probeHtml+'</td>'+ 
        '<td>'+esc24(pp.enabled?(pp.remarks||pp.id):'不使用')+'</td>'+ 
        '<td><div class="jfa-actions">'+ 
          '<input class="btn cbi-button cbi-button-edit" type="button" value="操作" onclick="openNode(\\''+idjs+'\\')"/>'+ 
          '<input class="btn cbi-button cbi-button-edit" type="button" value="重命名" onclick="renameNode(\\''+idjs+'\\')"/>'+ 
          '<input class="btn cbi-button cbi-button-remove" type="button" value="删除" onclick="deleteOneNode(\\''+idjs+'\\')"/>'+ 
          (aps.length?'<input class="btn cbi-button cbi-button-apply" type="button" value="检测" onclick="probeNode(\\''+idjs+'\\')"/>':'')+ 
        '</div></td></tr>';
    }
    body.innerHTML=html||'<tr><td colspan="7">没有匹配节点</td></tr>';
    updateBulk24();
  }

  window.renameNode=function(id){
    var cur=id, nodes=state.nodes||[];
    for(var i=0;i<nodes.length;i++) if(nodes[i].id===id){cur=nodes[i].remarks||id;break}
    var name=window.prompt('请输入新的节点名称',cur);
    if(name===null)return;
    name=name.replace(/^\s+|\s+$/g,'');
    if(!name){alert('节点名称不能为空');return}
    XHR.get(API24,{action:'rename_node',node:id,name:name},function(x,r){
      if(x&&x.status===200&&r&&r.ok){loadStatus()}
      else alert('重命名失败：'+((r&&r.error)||('HTTP '+(x?x.status:0))));
    });
  }

  function deleteBatch24(ids){
    if(!ids.length)return;
    var chunks=[], size=20;
    for(var i=0;i<ids.length;i+=size) chunks.push(ids.slice(i,i+size));
    var idx=0, deleted=0;
    function next(){
      if(idx>=chunks.length){
        state.selected={};
        var m=document.getElementById('jfa_msg'); if(m){m.textContent='✓ 已删除 '+deleted+' 个节点';m.className='jfa-ok'}
        loadStatus(); return;
      }
      XHR.get(API24,{action:'delete_nodes',nodes:chunks[idx].join(',')},function(x,r){
        if(x&&x.status===200&&r&&r.ok){
          deleted+=r.deleted_count||chunks[idx].length; idx++; next();
        }else{
          alert('删除失败：'+((r&&r.error)||('HTTP '+(x?x.status:0)))+(r&&r.rolled_back?'；已回滚':''));
          loadStatus();
        }
      });
    }
    next();
  }

  window.deleteOneNode=function(id){
    var label=id, nodes=state.nodes||[];
    for(var i=0;i<nodes.length;i++) if(nodes[i].id===id){label=nodes[i].remarks||id;break}
    if(!confirm('确定删除节点「'+label+'」？\\n已绑定无线会先解除；作为前置使用时会自动解除引用。'))return;
    deleteBatch24([id]);
  }

  window.deleteSelectedNodes=function(){
    var ids=[]; for(var id in state.selected) if(state.selected[id]) ids.push(id);
    if(!ids.length)return;
    if(!confirm('确定批量删除选中的 '+ids.length+' 个节点？\\n已绑定无线会先解除；相关前置引用会自动清理。'))return;
    deleteBatch24(ids);
  }

  var bar=document.querySelector('.jfa-commandbar');
  if(bar&&!document.getElementById('jfa_v24_delete')){
    var wrap=document.createElement('span');
    wrap.className='jfa-v24-bulk';
    wrap.innerHTML='<input id="jfa_v24_delete" class="btn cbi-button cbi-button-remove" type="button" value="删除选中" disabled="disabled" onclick="deleteSelectedNodes()"/><span id="jfa_v24_count" class="jfa-v24-count">已选 0 个</span>';
    bar.appendChild(wrap);
  }
  var tr=document.querySelector('.jfa-table thead tr');
  if(tr&&!document.getElementById('jfa_v24_all')){
    var th=document.createElement('th'); th.className='jfa-v24-select';
    th.innerHTML='<input id="jfa_v24_all" type="checkbox" title="全选当前筛选结果" onchange="toggleAllNodes(this.checked)"/>';
    tr.insertBefore(th,tr.firstChild);
  }
  var title=document.querySelector('.jfa-titlebar h2'); if(title) title.textContent='FastACL 2.4 控制台';
  renderNodes();
})();
</script>
]=]
  s = s:sub(1, p - 1) .. extra .. s:sub(p)
end

local o = assert(io.open(path, "wb"))
o:write(s)
o:close()
LUA

grep -q "$MARK_VIEW" "$VIEW" || {
  echo "[ERROR] view patch marker missing; rolling back" >&2
  cp -af "$BACKUP/console.htm" "$VIEW"
  cp -af "$BACKUP/juliang_fastacl.lua" "$CTRL"
  exit 1
}

uci set juliang_fastacl.main.version='2.4.0'
uci commit juliang_fastacl

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] JuLiang FastACL upgraded to 2.4"
echo "[OK] Added: single node delete + batch selection delete"
echo "[OK] Added: rename any imported node (SK5/HTTP/VLESS/Trojan/etc.)"
echo "[OK] Node rename keeps section ID unchanged, so wireless/preproxy bindings remain valid"
echo "[INFO] FastACL dataplane and proxy cores were not restarted"
echo "[INFO] Rollback backup: $BACKUP"
