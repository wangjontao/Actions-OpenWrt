from pathlib import Path
import base64,copy,json
from lupa.lua51 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]
lua=LuaRuntime(unpack_returned_tuples=True)
lua.execute('package.path='+json.dumps(str(ROOT/'root/usr/lib/lua/?.lua').replace('\\','/'))+"..';'..package.path")
def from_lua(v):
 if hasattr(v,'keys'):
  keys=list(v.keys())
  if keys and all(isinstance(k,int) for k in keys):return [from_lua(v[i]) for i in range(1,len(keys)+1)]
  return {k:from_lua(v[k]) for k in keys}
 return v
def to_lua(v):
 if isinstance(v,dict):return lua.table_from({k:to_lua(x) for k,x in v.items()})
 if isinstance(v,list):return lua.table_from([to_lua(x) for x in v])
 return v
lua.globals().pyencode=lambda v:json.dumps(from_lua(v))
lua.globals().pyb64encode=lambda v:base64.b64encode(v.encode()).decode()
lua.execute("package.preload['luci.jsonc']=function()return {stringify=pyencode}end; package.preload['nixio']=function()return {bin={b64encode=pyb64encode}}end")
policy=lua.eval("require('fastacl252')")
c=dict(network='lan',interface='br-lan',interfaces=['br-lan','br-jfa25w01','br-jfa25w02'],router_ip='192.168.7.1',netmask='255.255.255.0',port=12525,default_mode='direct',dns_policy='direct',dns_server='223.5.5.5',dns_name='dns.alidns.com',private_dns_server='1.1.1.1',private_dns_name='cloudflare-dns.com',fixed_exit=True,platform_secret='ab'*32,nodes={
 'us':dict(protocol='socks',address='203.0.113.1',port='1080'),
 'jp':dict(protocol='socks',address='203.0.113.2',port='1080')},devices=[dict(mac='02:00:00:00:00:01',ip='192.168.7.101',mode='proxy',node='us',dns='cloudflare')],wifis=[
 dict(id='jfa25w01',network='jfa25w01',interface='br-jfa25w01',subnet='172.16.1.0/24',router_ip='172.16.1.1',netmask='255.255.255.0',mode='proxy',node='us',dns='cloudflare'),
 dict(id='jfa25w02',network='jfa25w02',interface='br-jfa25w02',subnet='172.16.2.0/24',router_ip='172.16.2.1',netmask='255.255.255.0',mode='direct',dns='inherit')])
def compile(x):
 cfg,relay=policy.compile(to_lua(x));encoded=lua.eval("require('fastacl252_dae').encode_relay")(relay)
 return cfg,json.loads(encoded),from_lua(policy.firewall(to_lua(x),'nft'))['nft']
c['wifis'][0]['platforms']='youtube,tiktok'
original,relay,rules=compile(c)
for mutate in [lambda x:x['wifis'][0].update(node='jp'),lambda x:x['devices'][0].update(node='jp'),lambda x:x['wifis'][0].update(dns='google')]:
 changed=copy.deepcopy(c);mutate(changed);next_cfg,next_relay,next_rules=compile(changed)
 assert next_cfg==original,'Changing an existing exit rewrote dae config'
 assert next_rules==rules,'Changing an existing exit rewrote nft rules'
 assert isinstance(next_relay['data_slots'],dict)
 assert next_relay!=relay,'Exit selection was not recorded'
assert relay['data_slots']['wifi_jfa25w02']==0
assert '203.0.113.' not in original,'Real node credentials leaked into fixed datapath'
print('PASS: WiFi/device node and DNS changes preserve dae and nft configurations byte for byte')
