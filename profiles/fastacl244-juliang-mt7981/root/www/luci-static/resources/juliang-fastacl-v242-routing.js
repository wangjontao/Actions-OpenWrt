(function(){
'use strict';
var API=window.location.pathname.replace(/juliang_fastacl_console\/?$/,'juliang_fastacl_mode');
var data={aps:[],nodes:[]};
function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]})}
function xhr(p,cb){XHR.get(API,p,function(x,r){cb((x&&x.status===200)?r:null,x)})}
function ensureNodeTitle(){
  if(document.getElementById('jfa242_node_title'))return;
  var body=document.getElementById('jfa_body');
  if(!body)return;
  var sec=body;
  while(sec&&(!sec.className||String(sec.className).indexOf('cbi-section')<0))sec=sec.parentNode;
  if(!sec)return;
  var title=document.createElement('div');
  title.id='jfa242_node_title';
  title.style.cssText='display:flex;align-items:center;gap:10px;margin:2px 0 4px;padding:2px 2px 6px;border-bottom:1px solid rgba(128,128,128,.14)';
  title.innerHTML='<strong style="font-size:16px">节点分配（链式代理）</strong><span class="jfa-small">选择节点、分配无线、配置前置链路并查看实际出口</span>';
  sec.insertBefore(title,sec.firstChild);
}
function ensureUI(){
  ensureNodeTitle();
  if(document.getElementById('jfa242_route_section'))return;
  var host=document.querySelector('.jfa-head');
  if(!host)return;
  var box=document.createElement('details');
  box.id='jfa242_route_section';
  box.className='cbi-section';
  box.style.cssText='margin:4px 0 8px;padding:0 12px;border-radius:10px';
  box.innerHTML='<summary style="cursor:pointer;list-style:auto;padding:10px 0;font-weight:700">无线出口模式 <span id="jfa242_route_summary" class="jfa-small" style="margin-left:8px;font-weight:400">读取中…</span></summary>'+
    '<div style="padding:0 0 8px">'+
    '<div class="jfa-small" style="margin:0 0 6px">主 WiFi / 有线 LAN 默认国内直连；给它分配代理节点后自动切换为代理。其它无线可独立选择“代理节点”或“国内直连”。</div>'+
    '<table class="jfa-table"><thead><tr><th>无线 / 网络</th><th>当前模式</th><th>代理节点</th><th>操作</th></tr></thead><tbody id="jfa242_route_body"><tr><td colspan="4">读取中…</td></tr></tbody></table></div>';
  try{box.open=localStorage.getItem('jfa242-routing-open')==='1'}catch(e){}
  box.addEventListener('toggle',function(){try{localStorage.setItem('jfa242-routing-open',box.open?'1':'0')}catch(e){}});
  host.parentNode.insertBefore(box,host.nextSibling);
}
function nodeOptions(selected){
  var s='<option value="">请选择代理节点</option>';
  for(var i=0;i<data.nodes.length;i++){
    var n=data.nodes[i],sel=n.id===selected?' selected="selected"':'';
    s+='<option value="'+esc(n.id)+'"'+sel+'>'+esc(n.remarks||n.id)+' · '+esc((n.type||'')+'/'+(n.protocol||''))+'</option>';
  }
  return s;
}
function updateSummary(){
  var e=document.getElementById('jfa242_route_summary');if(!e)return;
  var direct=0,proxy=0;
  for(var i=0;i<data.aps.length;i++){if(data.aps[i].mode==='direct_cn')direct++;else proxy++;}
  e.textContent='国内直连 '+direct+' · 代理 '+proxy+' · 共 '+data.aps.length+' 个网络';
}
function render(){
  ensureUI();
  updateSummary();
  var body=document.getElementById('jfa242_route_body');if(!body)return;
  var h='';
  for(var i=0;i<data.aps.length;i++){
    var a=data.aps[i],direct=a.mode==='direct_cn';
    h+='<tr data-ap="'+esc(a.ap)+'">'+
      '<td><strong>'+esc(a.ssid||a.ap)+'</strong><div class="jfa-small">'+esc(a.network)+' · '+esc(a.subnet)+'</div></td>'+
      '<td><select class="cbi-input-select jfa242-mode" data-ap="'+esc(a.ap)+'">'+
        '<option value="direct_cn"'+(direct?' selected="selected"':'')+'>国内直连</option>'+
        '<option value="proxy"'+(!direct?' selected="selected"':'')+'>代理节点</option></select></td>'+
      '<td><select class="cbi-input-select jfa242-node" data-ap="'+esc(a.ap)+'" '+(direct?'disabled="disabled"':'')+'>'+nodeOptions(a.node)+'</select></td>'+
      '<td><input class="btn cbi-button cbi-button-apply jfa242-apply" data-ap="'+esc(a.ap)+'" type="button" value="应用"/></td></tr>';
  }
  body.innerHTML=h||'<tr><td colspan="4">没有发现无线网络</td></tr>';
}
function setGuardian(ok){
  var e=document.getElementById('st_guard');if(!e)return;
  e.textContent='Guardian：'+(ok?'运行':'未运行');
  e.className='jfa-pill '+(ok?'jfa-ok':'jfa-bad');
}
function load(){
  ensureUI();
  xhr({action:'status'},function(r){
    if(!r||!r.ok)return;
    data.aps=r.aps||[];data.nodes=r.nodes||[];setGuardian(!!r.guardian);render();
  });
}
function apply(ap){
  var m=document.querySelector('.jfa242-mode[data-ap="'+ap+'"]');
  var n=document.querySelector('.jfa242-node[data-ap="'+ap+'"]');
  if(!m||!n)return;
  var mode=m.value,node=n.value;
  if(mode==='proxy'&&!node){alert('请选择代理节点');return;}
  var btn=document.querySelector('.jfa242-apply[data-ap="'+ap+'"]');
  if(btn){btn.disabled=true;btn.value='应用中…';}
  xhr({action:'set_mode',ap:ap,mode:mode,node:node},function(r,x){
    if(btn){btn.disabled=false;btn.value='应用';}
    if(r&&r.ok){
      var msg=document.getElementById('jfa_msg');
      if(msg){msg.textContent='✓ '+ap+' 已切换为 '+(mode==='direct_cn'?'国内直连':'代理节点')+(r.switch&&r.switch.probe_async?'；出口 IP 后台检测中':'');msg.className='jfa-ok';}
      if(window.loadStatus)window.loadStatus();
      setTimeout(function(){if(window.loadStatus)window.loadStatus();load();},1800);
    }else{
      alert('切换失败：'+((r&&r.error)||('HTTP '+(x?x.status:0))));
      load();
    }
  });
}
function bind(){
  document.addEventListener('change',function(e){
    var t=e.target;
    if(!t||String(t.className).indexOf('jfa242-mode')<0)return;
    var ap=t.getAttribute('data-ap');
    var n=document.querySelector('.jfa242-node[data-ap="'+ap+'"]');
    if(n)n.disabled=t.value==='direct_cn';
  });
  document.addEventListener('click',function(e){
    var t=e.target;
    if(!t||String(t.className).indexOf('jfa242-apply')<0)return;
    apply(t.getAttribute('data-ap'));
  });
}
ensureUI();bind();load();
var old=window.loadStatus;
if(typeof old==='function'){
  window.loadStatus=function(){old.apply(this,arguments);setTimeout(load,250);};
}
setInterval(function(){xhr({action:'status'},function(r){if(r&&r.ok)setGuardian(!!r.guardian)})},15000);
})();
