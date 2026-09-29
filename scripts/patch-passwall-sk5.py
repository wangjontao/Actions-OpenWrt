#!/usr/bin/env python3
from pathlib import Path

APPS = [
    {
        "name": "PassWall",
        "frontend": Path("package/passwall-luci/luci-app-passwall/luasrc/view/passwall/node_list/link_add_node.htm"),
        "subscribe": Path("package/passwall-luci/luci-app-passwall/root/usr/share/passwall/subscribe.lua"),
        "xray": Path("package/passwall-luci/luci-app-passwall/luasrc/passwall/util_xray.lua"),
    },
    {
        "name": "PassWall2",
        "frontend": Path("package/passwall2-luci/luci-app-passwall2/luasrc/view/passwall2/node_list/link_add_node.htm"),
        "subscribe": Path("package/passwall2-luci/luci-app-passwall2/root/usr/share/passwall2/subscribe.lua"),
        "xray": Path("package/passwall2-luci/luci-app-passwall2/luasrc/passwall2/util_xray.lua"),
    },
]

FRONT_MARKER = "JuLiangTK: allow multiline SOCKS5 shorthand"
BACK_MARKER = "JuLiangTK: import SOCKS5/SOCKS provider shorthand"
XRAY_MARKER = 'mark = (node.protocol ~= "socks") and 255 or nil,'


def must_file(path: Path) -> None:
    if not path.is_file():
        raise SystemExit(f"required file missing: {path}")


def patch_frontend(path: Path) -> None:
    text = path.read_text()
    if FRONT_MARKER in text:
        return

    old = '''\t\tif (nodes_link != "") {
\t\t\tlet s = nodes_link.split('://');
\t\t\tif (s.length > 1) {
\t\t\t\tajax_add_node(nodes_link, group);
\t\t\t}
\t\t\telse {
\t\t\t\talert("<%:Please enter the correct link.%>");
\t\t\t}
\t\t}'''

    new = '''\t\tif (nodes_link != "") {
\t\t\t// JuLiangTK: allow multiline SOCKS5 shorthand: host:port:username:password
\t\t\tconst lines = nodes_link.split("\\n").map(function(v) { return v.trim(); }).filter(Boolean);
\t\t\tconst valid = lines.length > 0 && lines.every(function(v) {
\t\t\t\tif (v.indexOf("://") !== -1) return true;
\t\t\t\t// Avoid regex escaping mistakes: validate host:port:username:password by fields.
\t\t\t\tconst p = v.split(":");
\t\t\t\treturn p.length >= 4 && p[0].trim() !== "" && /^[0-9]+$/.test(p[1]) &&
\t\t\t\t\tNumber(p[1]) >= 1 && Number(p[1]) <= 65535 &&
\t\t\t\t\tp[2].trim() !== "" && p.slice(3).join(":") !== "";
\t\t\t});
\t\t\tif (valid) {
\t\t\t\tajax_add_node(nodes_link, group);
\t\t\t}
\t\t\telse {
\t\t\t\talert("<%:Please enter the correct link.%>");
\t\t\t}
\t\t}'''

    if old not in text:
        raise SystemExit(f"frontend anchor not found: {path}")
    text = text.replace(old, new, 1)

    help_old = "<%:Enter share links, one per line. Subscription links are not supported!%>"
    help_new = "<%:Enter share links or SOCKS5 shorthand (host:port:username:password), one per line. Subscription links are not supported!%>"
    if help_old in text:
        text = text.replace(help_old, help_new, 1)

    path.write_text(text)


def patch_subscribe(path: Path) -> None:
    text = path.read_text()
    if BACK_MARKER not in text:
        process_pos = text.find("local function processData")
        if process_pos < 0:
            raise SystemExit(f"processData not found: {path}")

        anchor = "\tif szType == 'ssr' then"
        branch_pos = text.find(anchor, process_pos)
        if branch_pos < 0:
            raise SystemExit(f"processData SSR anchor not found: {path}")

        branch = '''\t-- JuLiangTK: import SOCKS5/SOCKS provider shorthand as a normal node.
\tif szType == 'socks5' or szType == 'socks5h' or szType == 'socks' then
\t\tif not has_xray and not has_singbox then
\t\t\treturn nil
\t\tend
\t\tlocal link, fragment = content:match("^(.-)#(.*)$")
\t\tlink = link or content
\t\tlocal parsed = api.parseURL(szType .. "://" .. link)
\t\tif not parsed or not parsed.hostname or not parsed.port then
\t\t\treturn nil
\t\tend
\t\tlocal function pct_decode(v)
\t\t\treturn (v or ""):gsub("%%(%x%x)", function(h)
\t\t\t\treturn string.char(tonumber(h, 16))
\t\t\tend)
\t\tend
\t\tresult.type = has_xray and "Xray" or "sing-box"
\t\tresult.protocol = "socks"
\t\tresult.transport = "tcp"
\t\tresult.stream_security = "none"
\t\tresult.address = parsed.hostname
\t\tresult.port = parsed.port
\t\tresult.username = pct_decode(parsed.username)
\t\tresult.password = pct_decode(parsed.password)
\t\tresult.remarks = pct_decode(fragment or ("SK5-" .. result.address .. "-" .. tostring(result.port)))
\t\treturn result
\telseif szType == 'ssr' then'''

        text = text[:branch_pos] + branch + text[branch_pos + len(anchor):]

        parse_pos = text.find("local function parse_link")
        if parse_pos < 0:
            raise SystemExit(f"parse_link not found: {path}")
        node_token = "local node = api.trim(v)"
        node_pos = text.find(node_token, parse_pos)
        if node_pos < 0:
            raise SystemExit(f"parse_link node anchor not found: {path}")
        line_start = text.rfind("\n", 0, node_pos) + 1
        indent = text[line_start:node_pos]
        old_line = indent + node_token
        new_line = old_line + "\n" + \
            indent + "-- JuLiangTK: provider shorthand host:port:username:password -> socks5://\n" + \
            indent + 'local h, p, u, pw = node:match("^([^:]+):(%d+):([^:]+):(.+)$")\n' + \
            indent + "if h and p and u and pw then\n" + \
            indent + '\tnode = "socks5://" .. u .. ":" .. pw .. "@" .. h .. ":" .. p .. "#SK5-" .. h .. "-" .. p\n' + \
            indent + "end"

        if old_line not in text:
            raise SystemExit(f"parse_link exact anchor not found: {path}")
        text = text.replace(old_line, new_line, 1)

        path.write_text(text)

    verify = path.read_text()
    if BACK_MARKER not in verify or "provider shorthand host:port:username:password" not in verify:
        raise SystemExit(f"subscribe verification failed: {path}")


def patch_xray(path: Path) -> None:
    text = path.read_text()
    if XRAY_MARKER in text:
        return

    stream_pos = text.find('streamSettings = (node.streamSettings or node.protocol == "vmess"')
    if stream_pos < 0:
        raise SystemExit(f"generic Xray streamSettings anchor not found: {path}")

    mark_pos = text.find("mark = 255,", stream_pos)
    if mark_pos < 0 or mark_pos - stream_pos > 800:
        raise SystemExit(f"generic Xray mark anchor not found: {path}")

    text = text[:mark_pos] + XRAY_MARKER + text[mark_pos + len("mark = 255,"):]
    path.write_text(text)

    verify = path.read_text()
    if XRAY_MARKER not in verify:
        raise SystemExit(f"Xray mark verification failed: {path}")


def main() -> None:
    for app in APPS:
        for key in ("frontend", "subscribe", "xray"):
            must_file(app[key])
        patch_frontend(app["frontend"])
        patch_subscribe(app["subscribe"])
        patch_xray(app["xray"])

        front = app["frontend"].read_text()
        sub = app["subscribe"].read_text()
        xray = app["xray"].read_text()
        assert FRONT_MARKER in front
        assert BACK_MARKER in sub
        assert "provider shorthand host:port:username:password" in sub
        assert XRAY_MARKER in xray
        print(f"[OK] {app['name']}: multiline shorthand + SOCKS5 importer + Xray SOCKS mark fix")

    print("[OK] PassWall and PassWall2 SK5 node-list fixes applied successfully.")


if __name__ == "__main__":
    main()
