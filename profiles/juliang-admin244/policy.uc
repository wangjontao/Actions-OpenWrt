
// JuLiang restricted account policy: enforce scope in the menu and dispatch tree.
function juliang_scope_tree(node, path) {
    let full = join('/', path);
    let group;
    if (full == 'admin' || full == 'admin/juliang' || full == 'admin/juliang/api' || full == 'admin/network' || full == 'admin/services')
        group = 'juliang-navigation';
    else if (full == 'admin/logout' || full == 'admin/ubus' || full == 'admin/menu')
        group = 'juliang-navigation';
    else if (full == 'admin/juliang/dashboard' || full == 'admin/juliang/api/status' || full == 'admin/juliang/api/egress')
        group = 'juliang-dashboard-operator';
    else if (full == 'admin/juliang/wireless' || full == 'admin/juliang/api/wireless' || full == 'admin/juliang/api/wireless_set' || full == 'admin/network/wireless')
        group = 'juliang-wireless-operator';
    else if (length(path) == 3 && full == 'admin/services/' + path[2] && match(path[2], /^juliang_fastacl(_console|_mode|_runtime|_runtime_set|_wifi_status|_wifi|_dns|_dns_save)?$/))
        group = 'juliang-fastacl-operator';
    else if (length(path) && path[0] == 'admin')
        group = 'juliang-root-only';
    if (group) {
        node.depends ??= {};
        node.depends.acl = [group];
    }
    for (let name, child in node.children)
        juliang_scope_tree(child, [...path, name]);
}
