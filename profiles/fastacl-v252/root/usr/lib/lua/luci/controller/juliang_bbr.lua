module('luci.controller.juliang_bbr',package.seeall)
function index()
 local e=entry({'admin','juliang','bbr'},cbi('juliang_bbr'),_('BBR TCP 加速'),8)
 e.dependent=false
 e.acl_depends={'juliang-fastacl252'}
end
