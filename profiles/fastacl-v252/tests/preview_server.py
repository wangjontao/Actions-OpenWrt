"""Local demo backend for the FastACL 2.5.6 LuCI UI; no router access."""
import json, pathlib, re, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

ROOT=pathlib.Path(__file__).resolve().parents[1]
VERSION=re.search(r'^PKG_VERSION:=(.+)$',(ROOT/'package-Makefile').read_text(),re.M).group(1)
CATALOG=[
 {'id':'dns360','label':'360 安全 DNS','scope':'direct','kind':'doh'},
 {'id':'public114','label':'114 公共 DNS','scope':'direct','kind':'udp'},
 {'id':'cnnic','label':'CNNIC SDNS','scope':'direct','kind':'udp'},
 {'id':'baidu','label':'百度 DNS','scope':'direct','kind':'udp','ip':'180.76.76.76','name':''},
 {'id':'alidns','label':'阿里 DNS','scope':'direct','kind':'doh','ip':'223.5.5.5','name':'dns.alidns.com'},
 {'id':'tencent','label':'腾讯 DNSPod','scope':'direct','kind':'doh','ip':'1.12.12.12','name':'doh.pub'},
 {'id':'cloudflare','label':'Cloudflare','scope':'proxy','kind':'doh','ip':'1.1.1.1','name':'cloudflare-dns.com'},
 {'id':'google','label':'Google','scope':'proxy','kind':'doh','ip':'8.8.8.8','name':'dns.google'},
 {'id':'opendns','label':'Cisco OpenDNS','scope':'proxy','kind':'doh','ip':'208.67.222.222','name':'doh.opendns.com'},
 {'id':'quad9','label':'Quad9','scope':'proxy','kind':'doh','ip':'9.9.9.9','name':'dns.quad9.net'},
]
state={'ok':True,'version':VERSION+' · 本地演示','enabled':True,'direct_dns':'alidns','proxy_dns':'cloudflare','dns_catalog':CATALOG,
 'network':'lan','router_ip':'192.168.7.1','runtime':{'engine':'running','firewall':True,'backend':'nft','switch':'hot','request':'hot'},'job':'0','apply_log':'','subscription_running':False,
 'nodes':[{'id':'us','name':'美国出口 A','protocol':'socks'},{'id':'jp','name':'日本出口 B','protocol':'http'},{'id':'front','name':'前置节点','protocol':'vless'}],
 'subscriptions':[],
 'devices':[{'mac':'02:00:00:00:00:01','name':'手机 A','ip':'192.168.7.101','fixed_ip':'192.168.7.101','bound':True,'online':True,'mode':'proxy','node':'us','preproxy':'','dns':'inherit'},
            {'mac':'02:00:00:00:00:02','name':'手机 B','ip':'192.168.7.102','bound':False,'online':True,'mode':'direct','dns':'inherit'},
            {'mac':'02:00:00:00:00:03','name':'电脑 C','ip':'192.168.7.103','bound':True,'online':False,'mode':'direct','dns':'alidns'}],
 'wifi':{'radios':{'5g':['radio1'],'2g':['radio0']},'managed':[],'counts':{'5g':0,'2g':0},'max5':14,'max2':8}}


def bound_nodes():
    out=set()
    for d in state['devices']:
        if d.get('bound'):
            if d.get('node'):out.add(d['node'])
            if d.get('preproxy'):out.add(d['preproxy'])
    for w in state['wifi']['managed']:
        if w.get('node'):out.add(w['node'])
        if w.get('preproxy'):out.add(w['preproxy'])
    return out


class Handler(BaseHTTPRequestHandler):
    def reply(self,data):
        b=json.dumps(data,ensure_ascii=False).encode();self.send_response(200);self.send_header('Content-Type','application/json; charset=utf-8');self.end_headers();self.wfile.write(b)
    def do_GET(self):
        if self.path.endswith('/fastacl252_wireless'):
            t=time.monotonic();self.reply({'ok':True,'timestamp':t,'interfaces':[{'id':'phy1-ap0','ssid':'JuLiangTK','radio':'radio1','network':'lan','up':True,'stations':[{'mac':'02:00:00:00:00:01','name':'手机 A','ip':'192.168.7.101','signal':-51,'rx_bytes':int(t*100000),'tx_bytes':int(t*300000),'tx_link_mbps':866.7,'rx_link_mbps':780}]}]});return
        if self.path.endswith('/fastacl252_status'):self.reply(state);return
        if self.path not in ('/', '/index.html', '/wireless'):self.send_error(404);return
        text=(ROOT/('root/usr/lib/lua/luci/view/juliang_center/wireless.htm' if self.path=='/wireless' else 'root/usr/lib/lua/luci/view/fastacl252/console.htm')).read_text(encoding='utf-8')
        text=text.replace('<%+header%>','<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>FastACL Lite 演示</title><style>body{font:15px system-ui;background:#f4f6fa;color:#242b40;padding:24px}button{padding:8px 14px;border:1px solid #bbc4db;border-radius:6px;background:#fff}.cbi-button-apply,.cbi-button-add{background:#5263d9;color:white}input,select,textarea{padding:8px;border:1px solid #cbd1df;border-radius:6px}h3{margin-top:0}</style>')
        text=text.replace('<%+footer%>','</html>')
        text=re.sub(r'<%=luci.dispatcher.build_url\("admin","services"\)%>','/cgi-bin/luci/admin/services',text).replace('<%=token%>','demo-token').replace('<%=luci.dispatcher.build_url("admin","services","fastacl252_wireless")%>','/cgi-bin/luci/admin/services/fastacl252_wireless')
        self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.end_headers();self.wfile.write(text.encode())
    def do_POST(self):
        form=parse_qs(self.rfile.read(int(self.headers.get('Content-Length',0))).decode())
        if self.path.endswith('/fastacl252_rename_node'):
            node=next(n for n in state['nodes'] if n['id']==form['id'][0]);node['name']=form['name'][0]
            self.reply({'ok':True});return
        if self.path.endswith('/fastacl252_device_name'):
            row=next(r for r in state['devices'] if r['mac']==form['mac'][0]);name=form.get('name',[''])[0];row['name']=name;row['custom_name']=name
            self.reply({'ok':True,'name':name});return
        if self.path.endswith('/fastacl252_probe'):
            self.reply({'ok':True,'ip':'203.0.113.9','country':'JP','elapsed_ms':123,'proxy':True,'note':'绑定出口检测，非手机实机检测'});return
        if self.path.endswith('/fastacl252_save'):
            data=json.loads(form['data'][0]);state['direct_dns']=data.get('direct_dns',state['direct_dns']);state['proxy_dns']=data.get('proxy_dns',state['proxy_dns'])
            for d in data.get('devices',[]):
                r=next(r for r in state['devices'] if r['mac']==d['mac'])
                if d.get('remove'):r.update(bound=False,mode='direct',node='',preproxy='',dns='inherit')
                else:r.update(d,bound=True,fixed_ip=d['ip'],mode='proxy' if d.get('node') else 'direct')
            state['runtime']['switch']='hot';state['runtime']['request']='hot'
            self.reply({'ok':True,'message':'应用层快速切换完成；未重载 network / WiFi / firewall。'});return
        if self.path.endswith('/fastacl252_import'):
            lines=[x for x in form.get('links',[''])[0].splitlines() if x.strip()]
            for i,line in enumerate(lines,1):state['nodes'].append({'id':'manual'+str(len(state['nodes'])+1),'name':'手工节点 '+str(i),'protocol':'socks'})
            self.reply({'ok':True,'count':len(lines)});return
        if self.path.endswith('/fastacl252_wifi'):
            data=json.loads(form['data'][0]);a=data['action'];info=state['wifi']
            if a=='create':
                seq=len(info['managed'])+1
                for band,count in [('5g',int(data.get('count5',0))),('2g',int(data.get('count2',0)))]:
                    for _ in range(count):
                        idx=seq;seq+=1;ssid=str(data.get('prefix','A'))+str(int(data.get('start',1))+idx-1);net='jfa25w%02d'%idx;sub='172.16.%d.0/24'%idx
                        row={'id':net,'network':net,'ssid':ssid,'band':band,'subnet':sub,'mode':'proxy' if data.get('node') else 'direct','node':data.get('node',''),'preproxy':data.get('preproxy',''),'dns':data.get('dns','inherit'),'dns_type':data.get('dns_type',''),'dns_ip':data.get('dns_ip',''),'dns_name':data.get('dns_name','')}
                        info['managed'].append(row);info['counts'][band]+=1
                state['runtime']['switch']='app-restart';state['runtime']['request']='cold';msg='WiFi 拓扑已保存并重新加载。'
            elif a=='update':
                r=next(r for r in info['managed'] if r['id']==data['id']);r.update(data,mode='proxy' if data.get('node') else 'direct')
                state['runtime']['switch']='hot';state['runtime']['request']='hot';msg='节点已应用层快速切换；network / WiFi / firewall 均未重载。'
            elif a=='remove':
                r=next(r for r in info['managed'] if r['id']==data['id']);info['counts'][r['band']]-=1;info['managed'].remove(r);msg='WiFi 拓扑已保存并重新加载。'
            elif a=='hide_all':msg='SSID 显示状态已更新；未重载 network / firewall / dae。'
            else:self.reply({'ok':False,'error':'bad action'});return
            self.reply({'ok':True,'message':msg});return
        if self.path.endswith('/fastacl252_subscription'):
            data=json.loads(form['data'][0]);action=data['action']
            if action=='save':state['subscriptions'].append(dict(id='airport1',name=data['name'],interval_hours=data['interval_hours'],enabled=data['enabled'],status={}))
            elif action=='update':
                state['subscription_running']=True
                def done():
                    if state['subscriptions']:
                        state['nodes'].append(dict(id='airportnode',name='机场美国出口',protocol='socks',owner='airport1'));state['subscriptions'][0]['status']=dict(ok=True,count=1,attempt=int(time.time()))
                    state['subscription_running']=False
                threading.Timer(0.2,done).start()
            elif action=='remove':state['subscriptions']=[]
            self.reply({'ok':True});return
        if self.path.endswith('/fastacl252_delete_nodes'):
            data=json.loads(form['data'][0]);ids=data.get('ids',[]);bound=bound_nodes();deleted=[];skipped=[]
            for nid in ids:
                if nid in bound:skipped.append({'id':nid,'reason':'正在使用'})
                elif any(n['id']==nid for n in state['nodes']):deleted.append(nid)
                else:skipped.append({'id':nid,'reason':'节点不存在'})
            state['nodes']=[n for n in state['nodes'] if n['id'] not in deleted]
            self.reply({'ok':True,'deleted':deleted,'skipped':skipped,'message':f'已删除 {len(deleted)} 个节点；跳过 {len(skipped)} 个正在使用/无效节点。'});return
        if self.path.endswith('/fastacl252_delete_node'):
            nid=form.get('id',[''])[0]
            if nid in bound_nodes():self.reply({'ok':False,'error':'节点仍在使用'});return
            state['nodes']=[n for n in state['nodes'] if n['id']!=nid];self.reply({'ok':True});return
        self.send_error(404)
    def log_message(self,*args):pass

if __name__=='__main__':ThreadingHTTPServer(('127.0.0.1',8525),Handler).serve_forever()
