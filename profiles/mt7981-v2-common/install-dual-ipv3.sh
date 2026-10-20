#!/bin/sh
# JuLiang ISP public-IP widget for OpenWrt LuCI Argon
# Usage: sh install-dual-ip.sh [install|uninstall]
set -eu
ACTION="${1:-install}"
BASE=/www/luci-static/argon
CGI=/www/cgi-bin/juliang-exit-ip
SAVE=/etc/juliang-dual-ip-backup
HEADER=/usr/share/ucode/luci/template/themes/argon/header.ut
MARK='<!-- JuLiang exit IP card -->'

clean_header() {
    awk 'index($0,"<!-- JuLiang exit IP card -->") == 0 && index($0,"/luci-static/argon/exit-ip.css") == 0 && index($0,"/luci-static/argon/exit-ip.js") == 0' "$1"
}

if [ "$(id -u)" != 0 ]; then echo 'Please run as root.' >&2; exit 1; fi
case "$ACTION" in install|uninstall) ;; *) echo 'Usage: sh install-dual-ip.sh [install|uninstall]' >&2; exit 1;; esac
if [ "$ACTION" = uninstall ]; then
    [ -f "$SAVE/header.ut.original" ] || { echo "No installation backup found; nothing changed."; exit 0; }
    if [ -f "$HEADER" ]; then
        clean_header "$HEADER" > "$HEADER.jl-new"
        chmod 644 "$HEADER.jl-new"
        mv "$HEADER.jl-new" "$HEADER"
    fi
    for item in exit-ip.js exit-ip.css flags/cn.svg flags/us.svg; do
        if [ -f "$SAVE/assets/$item" ]; then
            mkdir -p "$BASE/$(dirname "$item")"
            cp -p "$SAVE/assets/$item" "$BASE/$item"
        else
            rm -f "$BASE/$item"
        fi
    done
    if [ -f "$SAVE/cgi-original" ]; then cp -p "$SAVE/cgi-original" "$CGI"; else rm -f "$CGI"; fi
    echo 'Uninstalled. Refresh LuCI. Backups retained in /etc/juliang-dual-ip-backup.'
    exit 0
fi

test -s "$HEADER" || { echo 'Unsupported theme: Argon header.ut was not found. Nothing changed.' >&2; exit 1; }
grep -q 'sidenav-header' "$HEADER" || { echo 'Unsupported Argon layout. Nothing changed.' >&2; exit 1; }
for tool in curl jsonfilter awk ubus; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing dependency: $tool. curl/jsonfilter can be installed with opkg; awk and ubus must be provided by the firmware." >&2; exit 1; }
done
STAGE=$(mktemp -d /tmp/juliang-dual-ip.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT INT TERM
mkdir -p "$STAGE/flags"
cat > "$STAGE/exit-ip.js" <<'JL_ASSET_END'
(function(){
'use strict';
function mount(){
var menu=document.querySelector('.main-left');if(!menu||document.getElementById('jl-exit-card'))return;
var card=document.createElement('button');card.type='button';card.id='jl-exit-card';card.className='jl-exit-card';card.title='运营商公网 IP · 点击刷新';
function row(id,title){return '<section class="jl-ip-row" data-exit="'+id+'"><span class="jl-exit-title"><span>'+title+'</span><span class="jl-exit-refresh">↻</span></span><span class="jl-exit-ip">查询中…</span><span class="jl-exit-place"><img hidden alt=""><span>正在获取国家与地区</span></span></section>';}
card.innerHTML=row('isp','运营商公网 IP');
var header=menu.querySelector('.sidenav-header');if(header)header.after(card);else menu.prepend(card);
var busy=false;
async function query(url){var ctl=new AbortController();var timer=setTimeout(function(){ctl.abort();},14000);try{var r=await fetch(url,{cache:'no-store',credentials:'omit',signal:ctl.signal});if(!r.ok)throw Error('HTTP '+r.status);var d=await r.json();if(d.success===false||d.error||!d.ip)throw Error(d.message||'lookup');return d;}finally{clearTimeout(timer);}}
function render(id,d){var row=card.querySelector('[data-exit="'+id+'"]');row.querySelector('.jl-exit-ip').textContent=d.ip;var country=d.country_name||d.country;var region=[country,d.region,d.city].filter(function(v,i,a){return v&&a.indexOf(v)===i;});row.querySelector('.jl-exit-place span').textContent=region.join(' · ');var img=row.querySelector('img');img.hidden=true;if(/^[A-Z]{2}$/.test(d.country_code)){img.src='/luci-static/argon/flags/'+d.country_code.toLowerCase()+'.svg';img.alt=country+'国旗';img.hidden=false;img.onerror=function(){this.onerror=function(){this.hidden=true;};this.src='https://cdn.ipwhois.io/flags/'+d.country_code.toLowerCase()+'.svg';};}row.title=region.join(' · ');row.dataset.ip=d.ip;}
function fail(id,error){var row=card.querySelector('[data-exit="'+id+'"]');row.querySelector('.jl-exit-ip').textContent='查询失败';row.querySelector('.jl-exit-place span').textContent='点击卡片重试';row.querySelector('img').hidden=true;delete row.dataset.ip;}
async function refresh(){if(busy||document.hidden)return;busy=true;card.setAttribute('aria-busy','true');try{render('isp',await query('/cgi-bin/juliang-exit-ip?isp'));card.title='运营商公网 IP · '+new Date().toLocaleTimeString()+' 更新，点击刷新';}catch(e){fail('isp',e);}finally{busy=false;card.setAttribute('aria-busy','false');}}
card.addEventListener('click',refresh);refresh();setInterval(refresh,60000);document.addEventListener('visibilitychange',function(){if(!document.hidden)refresh();});
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',mount);else mount();
})();
JL_ASSET_END
cat > "$STAGE/exit-ip.css" <<'JL_ASSET_END'
.jl-exit-card{display:block!important;position:relative;margin:0 16px 18px;padding:15px 16px;border:0;border-radius:16px;background:linear-gradient(125deg,#5267e8 0%,#7956d8 55%,#b45ac7 100%);color:#fff!important;box-shadow:0 8px 22px rgba(92,83,202,.25);text-align:left;cursor:pointer;max-width:calc(100% - 32px);font-family:inherit;line-height:1.5;overflow:hidden}.jl-exit-card::after{content:"";position:absolute;width:100px;height:100px;right:-32px;top:-45px;border-radius:50%;background:rgba(255,255,255,.09);pointer-events:none}.jl-exit-title{display:flex;align-items:center;justify-content:space-between;font-size:11px;letter-spacing:1px;opacity:.85}.jl-exit-ip{display:block;font-size:21px;font-weight:700;letter-spacing:.2px;margin:7px 0 6px;font-variant-numeric:tabular-nums;white-space:nowrap}.jl-exit-place{display:flex;align-items:center;gap:7px;font-size:12px;white-space:normal}.jl-exit-place img{width:23px;height:16px;object-fit:cover;border-radius:3px;box-shadow:0 1px 4px #0002}.jl-exit-refresh{font-size:15px;letter-spacing:0}.jl-exit-card:focus-visible{outline:2px solid #fff;outline-offset:-4px}.jl-exit-card[aria-busy=true] .jl-exit-refresh{animation:jl-spin 1s linear infinite}@keyframes jl-spin{to{transform:rotate(360deg)}}

#jl-exit-card{height:auto!important;min-height:116px!important;box-sizing:border-box!important;white-space:normal!important;width:calc(100% - 32px)!important}#jl-exit-card .jl-exit-ip{font-size:19px!important;line-height:1.4!important}#jl-exit-card .jl-exit-title{line-height:1.5!important}#jl-exit-card .jl-exit-place{line-height:1.6!important;font-size:11px!important}

#jl-exit-card{padding:13px 14px!important;min-height:0!important}#jl-exit-card .jl-ip-row{display:block;min-width:0;padding:0!important;margin:0!important}#jl-exit-card .jl-ip-row+.jl-ip-row{margin-top:12px!important;padding-top:12px!important;border-top:1px solid rgba(255,255,255,.25)}#jl-exit-card .jl-exit-ip{font-size:18px!important;overflow-wrap:anywhere;white-space:normal}#jl-exit-card .jl-exit-place{align-items:flex-start;text-align:left}#jl-exit-card .jl-exit-place img{flex-shrink:0;margin-top:1px}#jl-exit-card .jl-exit-title{letter-spacing:.5px}
JL_ASSET_END
cat > "$STAGE/juliang-exit-ip" <<'JL_ASSET_END'
#!/bin/sh
# ISP is queried by the router; proxy mode always uses HomeProxy's SOCKS inlet.
printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
MODE="${QUERY_STRING:-isp}"
TMP=$(mktemp /tmp/juliang-exit-query.XXXXXX) || exit 1
trap 'rm -f "$TMP"' EXIT INT TERM
fail() { printf '{"success":false,"message":"%s"}' "$1"; exit 0; }
case "$MODE" in
proxy)
  COUNT=0
  PLUGIN=''
  PORT=''
  # Require an active process as well as enabled configuration, so stale
  # runtime files from a stopped plugin cannot select an unrelated listener.
  PROCS=$(ps w)
  if printf '%s\n' "$PROCS" | grep -q '[s]ing-box.*[/]var/run/homeproxy/sing-box-c.json'; then
    CONFIG=/var/run/homeproxy/sing-box-c.json
    PORT=$(jsonfilter -i "$CONFIG" -e '@.inbounds[@.type="mixed"].listen_port' 2>/dev/null | head -n 1)
    PLUGIN=HomeProxy
    COUNT=$((COUNT + 1))
  fi
  for APP in passwall passwall2; do
    [ "$(uci -q get "$APP.@global[0].enabled")" = 1 ] || continue
    printf '%s\n' "$PROCS" | grep -q "/tmp/etc/$APP/" || continue
    if [ "$APP" = passwall ]; then KEY=GLOBAL_TCP_SOCKS_server; else KEY=GLOBAL_SOCKS_server; fi
    # Read actual runtime port, not UCI/default 1070: PassWall can move the port.
    ADDR=$(awk -F '"' -v key="$KEY" 'index($0,key "=")==1 {v=$2} END {print v}' "/tmp/etc/$APP/var" 2>/dev/null)
    case "$ADDR" in 127.0.0.1:*) PORT=${ADDR##*:};; *) PORT='';; esac
    if [ "$APP" = passwall ]; then PLUGIN=PassWall; else PLUGIN=PassWall2; fi
    COUNT=$((COUNT + 1))
  done
  [ "$COUNT" -gt 0 ] || fail '未检测到可用代理，支持 HomeProxy / PassWall / PassWall2'
  [ "$COUNT" -eq 1 ] || fail '检测到多个代理插件运行，无法确定主出口'
  case "$PORT" in ''|*[!0-9]*) fail '代理运行时 SOCKS 入口不存在';; esac
  [ "$PORT" -gt 0 ] && [ "$PORT" -le 65535 ] || fail '代理端口无效'
  # socks5h resolves the query hostname through the router proxy, not local DNS.
  curl -4 -fsS --noproxy '' --proxy "socks5h://127.0.0.1:$PORT" \
    --connect-timeout 4 --max-time 10 'https://ipwho.is/?lang=zh-CN' -o "$TMP" 2>/dev/null \
    || fail '路由器代理出口查询失败，请检查当前代理节点'
  ;;
isp|'')
  CACHE=/tmp/juliang-exit-isp-wan.json
  NOW=$(date +%s)
  OLD=$(cat "$CACHE.time" 2>/dev/null || echo 0)
  case "$OLD" in ''|*[!0-9]*) OLD=0;; esac
  if [ -s "$CACHE" ] && [ "$NOW" -ge "$OLD" ] && [ "$((NOW - OLD))" -lt 60 ]; then cat "$CACHE"; exit 0; fi
  WAN=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
  [ -n "$WAN" ] || fail '未检测到 WAN 接口，无法确认运营商出口'
  curl -4 -fsS --interface "$WAN" --noproxy '*' --connect-timeout 3 --max-time 8 \
    'https://ipwho.is/?lang=zh-CN' -o "$TMP" 2>/dev/null || fail '运营商出口查询失败'
  ;;
*) fail '不支持的查询类型';;
esac
[ "$(jsonfilter -i "$TMP" -e '@.success' 2>/dev/null)" = true ] || fail '出口查询服务暂不可用'
if [ "$MODE" != proxy ]; then
  cp "$TMP" "$CACHE"
  printf '%s\n' "$NOW" > "$CACHE.time"
fi
if [ "$MODE" = proxy ]; then
  printf '{"proxy_plugin":"%s",' "$PLUGIN"
  sed '1s/^[[:space:]]*{//' "$TMP"
else
  cat "$TMP"
fi
JL_ASSET_END
cat > "$STAGE/flags/cn.svg" <<'JL_FLAG_END'
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="640" height="480" viewBox="-5 -5 12.8 9.6">
  <title>
    Flag of the People&apos;s Republic of China
  </title>
  <defs>
    <path id="b" fill="#ffde00" d="M-.588.81L0-1 .588.81-.952-.31H.952z"/>
    <clipPath id="a">
      <path d="M-5-15.4h26.667v20H-5z"/>
    </clipPath>
  </defs>
  <g transform="matrix(.48 0 0 .48 -2.6 2.39)" clip-path="url(#a)">
    <path fill="#de2910" d="M-5-15.4h30v20H-5z"/>
    <use height="20" width="30" transform="matrix(3 0 0 3 0 -10.4)" xlink:href="#b"/>
    <use height="20" width="30" transform="rotate(-120.93 -1.29 -8.12)" xlink:href="#b"/>
    <use height="20" width="30" transform="rotate(-98.11 -1.45 -8.74)" xlink:href="#b"/>
    <use height="20" width="30" transform="rotate(-74.04 -2.07 -8.84)" xlink:href="#b"/>
    <use height="20" width="30" transform="rotate(-51.32 -4.16 -8.4)" xlink:href="#b"/>
  </g>
</svg>
JL_FLAG_END
cat > "$STAGE/flags/us.svg" <<'JL_FLAG_END'
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg id="svg153" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://www.w3.org/2000/svg" height="480" width="640" version="1.1" xmlns:cc="http://creativecommons.org/ns#" xmlns:dc="http://purl.org/dc/elements/1.1/">
 <metadata id="metadata3151">
  <rdf:RDF>
   <cc:Work rdf:about="">
  <dc:format>image/svg+xml</dc:format>
  <dc:type rdf:resource="http://purl.org/dc/dcmitype/StillImage"/>
   </cc:Work>
  </rdf:RDF>
 </metadata>
 <desc id="desc3066">The United States of America flag, produced by Daniel McRae</desc>
 <defs id="defs155">
  <clipPath id="clipPath4293" clipPathUnits="userSpaceOnUse">
   <rect id="rect4295" fill-opacity="0.67" height="512" width="682.67" y=".0000052307" x="0"/>
  </clipPath>
 </defs>
 <g id="flag" fill-rule="evenodd" clip-path="url(#clipPath4293)" transform="matrix(.93750 0 0 .93750 0 -.0000049038)">
  <g id="g390" stroke-width="1pt" transform="matrix(3.9385 0 0 3.9385 0 .000005)">
   <g id="g169" fill="#bd3d44">
  <rect id="rect156" height="10" width="247" y="0" x="0"/>
  <rect id="rect158" height="10" width="247" y="20" x="0"/>
  <rect id="rect160" height="10" width="247" y="40" x="0"/>
  <rect id="rect162" height="10" width="247" y="60" x="0"/>
  <rect id="rect164" height="10" width="247" y="80" x="0"/>
  <rect id="rect166" height="10" width="247" y="100" x="0"/>
  <rect id="rect168" height="10" width="247" y="120" x="0"/>
   </g>
   <g id="g177" fill="#fff">
  <rect id="rect157" height="10" width="247" y="10" x="0"/>
  <rect id="rect159" height="10" width="247" y="30" x="0"/>
  <rect id="rect161" height="10" width="247" y="50" x="0"/>
  <rect id="rect163" height="10" width="247" y="70" x="0"/>
  <rect id="rect165" height="10" width="247" y="90" x="0"/>
  <rect id="rect167" height="10" width="247" y="110" x="0"/>
   </g>
  </g>
  <rect id="rect200" height="275.69" width="389.12" y="0.000005" x="0" stroke-width="1pt" fill="#192f5d"/>
  <g id="g274" fill="#fff" transform="matrix(3.9385 0 0 3.9385 0 .000005)">
   <g id="g218">
  <g id="g194">
   <polygon id="polygon207" transform="translate(8.2333 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon188" transform="translate(24.7,7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon189" transform="translate(41.167 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon190" transform="translate(57.633 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon191" transform="translate(74.1,7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon192" transform="translate(90.567 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
  </g>
  <g id="g205">
   <polygon id="polygon193" transform="translate(16.467 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon201" transform="translate(32.933 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon202" transform="translate(49.4,14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon203" transform="translate(65.867 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon204" transform="translate(82.333 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
  </g>
   </g>
   <g id="g232" transform="translate(0,14)">
  <g id="g233">
   <polygon id="polygon234" transform="translate(8.2333 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon235" transform="translate(24.7,7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon236" transform="translate(41.167 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon237" transform="translate(57.633 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon238" transform="translate(74.1,7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon239" transform="translate(90.567 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
  </g>
  <g id="g240">
   <polygon id="polygon241" transform="translate(16.467 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon242" transform="translate(32.933 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon243" transform="translate(49.4,14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon244" transform="translate(65.867 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon245" transform="translate(82.333 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
  </g>
   </g>
   <g id="g246" transform="translate(0,28)">
  <g id="g247">
   <polygon id="polygon248" transform="translate(8.2333 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon249" transform="translate(24.7,7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon250" transform="translate(41.167 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon251" transform="translate(57.633 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon252" transform="translate(74.1,7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon253" transform="translate(90.567 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
  </g>
  <g id="g254">
   <polygon id="polygon255" transform="translate(16.467 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon256" transform="translate(32.933 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon257" transform="translate(49.4,14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon258" transform="translate(65.867 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon259" transform="translate(82.333 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
  </g>
   </g>
   <g id="g260" transform="translate(0,42)">
  <g id="g261">
   <polygon id="polygon262" transform="translate(8.2333 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon263" transform="translate(24.7,7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon264" transform="translate(41.167 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon265" transform="translate(57.633 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon266" transform="translate(74.1,7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon267" transform="translate(90.567 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
  </g>
  <g id="g268">
   <polygon id="polygon269" transform="translate(16.467 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon270" transform="translate(32.933 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon271" transform="translate(49.4,14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon272" transform="translate(65.867 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   <polygon id="polygon273" transform="translate(82.333 14)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
  </g>
   </g>
   <g id="g211" transform="translate(0,56)">
  <polygon id="polygon212" transform="translate(8.2333 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
  <polygon id="polygon213" transform="translate(24.7,7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
  <polygon id="polygon214" transform="translate(41.167 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
  <polygon id="polygon215" transform="translate(57.633 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
  <polygon id="polygon216" transform="translate(74.1,7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
  <polygon id="polygon217" transform="translate(90.567 7)" d="M 1.3084868e-6,-4.0040002 0.89895399,-1.237304 3.8080309,-1.2373029 1.4545381,0.47260808 2.3534912,3.239305 0,1.5293919 l -2.3534933,1.7099115 0.8989552,-2.76669531 -2.353492,-1.70991339 2.9090761,1.3e-6 z" points="0 -4.004 0.89895 -1.2373 3.808 -1.2373 1.4545 0.47261 2.3535 3.2393 0 1.5294 -2.3535 3.2393 -1.4545 0.47261 -3.808 -1.2373 -0.89895 -1.2373"/>
   </g>
  </g>
 </g>
</svg>
JL_FLAG_END
sh -n "$STAGE/juliang-exit-ip"
clean_header "$HEADER" | awk '
    /<\/head>/ {
        print "<!-- JuLiang exit IP card -->"
        print "<link rel=\"stylesheet\" href=\"/luci-static/argon/exit-ip.css?v=isp-only-255\">"
        print "<script defer src=\"/luci-static/argon/exit-ip.js?v=isp-only-255\"></script>"
    }
    { print }
' > "$STAGE/header.ut"
grep -q 'exit-ip.js?v=isp-only-255' "$STAGE/header.ut" || { echo 'No head closing tag; aborting.' >&2; exit 1; }
mkdir -p "$SAVE/assets/flags" "$BASE/flags"
if [ ! -f "$SAVE/header.ut.original" ]; then
    cp -p "$HEADER" "$SAVE/header.ut.original"
    for item in exit-ip.js exit-ip.css flags/cn.svg flags/us.svg; do
        if [ -f "$BASE/$item" ]; then cp -p "$BASE/$item" "$SAVE/assets/$item"; fi
    done
    if [ -f "$CGI" ]; then cp -p "$CGI" "$SAVE/cgi-original"; fi
fi
for item in exit-ip.js exit-ip.css flags/cn.svg flags/us.svg; do
    cp "$STAGE/$item" "$BASE/$item"
    chmod 644 "$BASE/$item"
done
cp "$STAGE/juliang-exit-ip" "$CGI"
chmod 755 "$CGI"
cp "$STAGE/header.ut" "$HEADER.jl-new"
chmod 644 "$HEADER.jl-new"
mv "$HEADER.jl-new" "$HEADER"
echo 'Installed: ISP public IP only.'
echo 'Refresh LuCI with Ctrl+F5. Click the card to refresh; automatic refresh every 60 seconds.'
echo 'Uninstall: sh install-dual-ip.sh uninstall'

