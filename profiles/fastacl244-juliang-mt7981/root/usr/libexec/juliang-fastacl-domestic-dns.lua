local json=require 'luci.jsonc'
local u=require('luci.model.uci').cursor()
local dns=require('juliang_fastacl_dns').get(u,'domestic');dns.tag='domestic';dns.detour=nil
local c={log={level='warn'},dns={servers={dns},final='domestic'},inbounds={{type='direct',tag='dns-in',listen='127.0.0.1',listen_port=5354}},outbounds={{type='direct',tag='direct'}},route={rules={{action='sniff'},{protocol='dns',action='hijack-dns'}},final='direct'}}
io.write(json.stringify(c,true))
