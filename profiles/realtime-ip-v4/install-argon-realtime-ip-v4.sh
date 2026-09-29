#!/bin/sh

set -e

VERSION="4.0.0"

echo "=================================================="
echo " Argon 公网 IP + 国家/省州/城市显示工具 v${VERSION}"
echo "=================================================="

# ============================================================
# 0. 基础检查
# ============================================================

if ! command -v jsonfilter >/dev/null 2>&1; then
    echo "[错误] 系统缺少 jsonfilter，无法解析 IP 定位数据。"
    echo "可尝试执行：opkg update && opkg install jsonfilter"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "[错误] 系统同时缺少 curl 和 wget，无法访问 IP 查询服务。"
    exit 1
fi

# ============================================================
# 1. 查找 Argon 主题模板
# ============================================================

HEADER=""

for FILE in \
    /usr/share/ucode/luci/template/themes/argon/header.ut \
    /usr/lib/lua/luci/view/themes/argon/header.htm
do
    if [ -f "$FILE" ]; then
        HEADER="$FILE"
        break
    fi
done

if [ -z "$HEADER" ]; then
    echo "[错误] 没有找到 Argon 主题模板。"
    echo "当前主题：$(uci -q get luci.main.mediaurlbase || echo 未知)"
    exit 1
fi

echo "[信息] Argon 模板：$HEADER"

# ============================================================
# 2. 备份主题模板
# ============================================================

BACKUP="${HEADER}.realtime-ip-backup-$(date +%Y%m%d-%H%M%S)"
cp -a "$HEADER" "$BACKUP"
echo "[信息] 已备份到：$BACKUP"

# ============================================================
# 3. 创建公网 IP 与地理位置检测程序
# ============================================================

cat > /usr/bin/argon-public-ip <<'EOF'
#!/bin/sh

CACHE_FILE="/tmp/argon-public-ip.json"
TIME_FILE="/tmp/argon-public-ip.time"
CACHE_SECONDS=60
FORCE=0

[ "$1" = "--force" ] && FORCE=1

is_ipv4()
{
    printf '%s\n' "$1" | awk -F. '
    NF != 4 { bad = 1 }
    {
        for (i = 1; i <= 4; i++) {
            if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255)
                bad = 1
        }
    }
    END { exit bad }
    '
}

json_escape()
{
    printf '%s' "$1" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g' \
        -e 's/\t/ /g' | tr '\r\n' '  '
}

json_get()
{
    printf '%s' "$1" | jsonfilter -e "$2" 2>/dev/null
}

download()
{
    URL="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsSL \
            --connect-timeout 5 \
            --max-time 10 \
            -A 'OpenWrt-Argon-IP/4.0' \
            "$URL" 2>/dev/null
        return
    fi

    wget -qO- -T 10 \
        --user-agent='OpenWrt-Argon-IP/4.0' \
        "$URL" 2>/dev/null
}

write_result()
{
    IP="$1"
    COUNTRY="$2"
    COUNTRY_CODE="$3"
    REGION="$4"
    CITY="$5"
    ISP="$6"
    FLAG="$7"
    PROVIDER="$8"

    NOW_EPOCH="$(date +%s)"
    UPDATE_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
    TMP_FILE="${CACHE_FILE}.tmp.$$"

    printf '{"ok":true,"ip":"%s","country":"%s","country_code":"%s","region":"%s","city":"%s","isp":"%s","flag":"%s","provider":"%s","time":"%s","timestamp":%s}\n' \
        "$(json_escape "$IP")" \
        "$(json_escape "$COUNTRY")" \
        "$(json_escape "$COUNTRY_CODE")" \
        "$(json_escape "$REGION")" \
        "$(json_escape "$CITY")" \
        "$(json_escape "$ISP")" \
        "$(json_escape "$FLAG")" \
        "$(json_escape "$PROVIDER")" \
        "$(json_escape "$UPDATE_TIME")" \
        "$NOW_EPOCH" > "$TMP_FILE"

    mv "$TMP_FILE" "$CACHE_FILE"
    printf '%s\n' "$NOW_EPOCH" > "$TIME_FILE"
    cat "$CACHE_FILE"
    exit 0
}

NOW="$(date +%s)"
LAST="$(cat "$TIME_FILE" 2>/dev/null || echo 0)"

case "$LAST" in
    ''|*[!0-9]*) LAST=0 ;;
esac

if [ "$FORCE" = "0" ] && [ -s "$CACHE_FILE" ] && [ $((NOW - LAST)) -lt "$CACHE_SECONDS" ]; then
    cat "$CACHE_FILE"
    exit 0
fi

# ------------------------------------------------------------
# 数据源 1：ipwho.is（HTTPS，支持中文国家/省州/城市）
# ------------------------------------------------------------

RAW="$(download 'https://ipwho.is/?lang=zh' || true)"

if [ -n "$RAW" ]; then
    SUCCESS="$(json_get "$RAW" '@.success')"
    IP="$(json_get "$RAW" '@.ip')"

    if { [ "$SUCCESS" = "true" ] || [ "$SUCCESS" = "1" ]; } && is_ipv4 "$IP"; then
        write_result \
            "$IP" \
            "$(json_get "$RAW" '@.country')" \
            "$(json_get "$RAW" '@.country_code')" \
            "$(json_get "$RAW" '@.region')" \
            "$(json_get "$RAW" '@.city')" \
            "$(json_get "$RAW" '@.connection.isp')" \
            "$(json_get "$RAW" '@.flag.emoji')" \
            "ipwho.is"
    fi
fi

# ------------------------------------------------------------
# 数据源 2：ipapi.co（HTTPS 备用）
# ------------------------------------------------------------

RAW="$(download 'https://ipapi.co/json/' || true)"

if [ -n "$RAW" ]; then
    IP="$(json_get "$RAW" '@.ip')"
    ERROR="$(json_get "$RAW" '@.error')"

    if [ "$ERROR" != "true" ] && is_ipv4 "$IP"; then
        write_result \
            "$IP" \
            "$(json_get "$RAW" '@.country_name')" \
            "$(json_get "$RAW" '@.country')" \
            "$(json_get "$RAW" '@.region')" \
            "$(json_get "$RAW" '@.city')" \
            "$(json_get "$RAW" '@.org')" \
            "" \
            "ipapi.co"
    fi
fi

# ------------------------------------------------------------
# 数据源 3：ip-api.com（HTTP 最后备用）
# ------------------------------------------------------------

RAW="$(download 'http://ip-api.com/json/?lang=zh-CN&fields=status,message,country,countryCode,regionName,city,isp,query' || true)"

if [ -n "$RAW" ]; then
    STATUS="$(json_get "$RAW" '@.status')"
    IP="$(json_get "$RAW" '@.query')"

    if [ "$STATUS" = "success" ] && is_ipv4 "$IP"; then
        write_result \
            "$IP" \
            "$(json_get "$RAW" '@.country')" \
            "$(json_get "$RAW" '@.countryCode')" \
            "$(json_get "$RAW" '@.regionName')" \
            "$(json_get "$RAW" '@.city')" \
            "$(json_get "$RAW" '@.isp')" \
            "" \
            "ip-api.com"
    fi
fi

# 所有数据源失败时，优先返回旧缓存
if [ -s "$CACHE_FILE" ]; then
    cat "$CACHE_FILE"
    exit 0
fi

UPDATE_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
printf '{"ok":false,"ip":"-","country":"","country_code":"","region":"","city":"","isp":"","flag":"","provider":"","time":"%s","message":"获取失败"}\n' \
    "$(json_escape "$UPDATE_TIME")"

exit 1
EOF

chmod 755 /usr/bin/argon-public-ip

# ============================================================
# 4. 创建网页 CGI 接口
# ============================================================

mkdir -p /www/cgi-bin

cat > /www/cgi-bin/argon-realtime-ip <<'EOF'
#!/bin/sh

printf 'Content-Type: application/json; charset=UTF-8\r\n'
printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
printf 'Pragma: no-cache\r\n'
printf 'X-Content-Type-Options: nosniff\r\n'
printf '\r\n'

case "&${QUERY_STRING}&" in
    *'&force=1&'*)
        /usr/bin/argon-public-ip --force
        ;;
    *)
        /usr/bin/argon-public-ip
        ;;
esac
EOF

chmod 755 /www/cgi-bin/argon-realtime-ip

# ============================================================
# 5. 创建 Argon 左上角前端程序
# ============================================================

mkdir -p /www/luci-static/argon

cat > /www/luci-static/argon/realtime-ip.js <<'EOF'
(function () {
    'use strict';

    var root = document.getElementById('argon-realtime-ip');

    if (!root || root.getAttribute('data-started') === '1')
        return;

    root.setAttribute('data-started', '1');

    var flagElement = document.getElementById('argon-realtime-flag');
    var ipElement = document.getElementById('argon-realtime-address');
    var locationElement = document.getElementById('argon-realtime-location');
    var busy = false;

    function flagFromCode(code) {
        code = String(code || '').trim().toUpperCase();

        if (!/^[A-Z]{2}$/.test(code))
            return '🌐';

        return String.fromCodePoint(
            127397 + code.charCodeAt(0),
            127397 + code.charCodeAt(1)
        );
    }

    function joinLocation(data) {
        var parts = [];

        if (data.country)
            parts.push(data.country);

        if (data.region && data.region !== data.country)
            parts.push(data.region);

        if (data.city && data.city !== data.region)
            parts.push(data.city);

        return parts.length ? parts.join(' · ') : '位置未知';
    }

    function setLoading() {
        root.classList.remove('argon-ip-error');
        root.classList.add('argon-ip-loading');
        root.style.opacity = '0.78';
        flagElement.textContent = '🌐';
        ipElement.textContent = '检测中…';
        locationElement.textContent = '正在查询国家和位置';
    }

    function render(data) {
        data = data || {};

        var flag = data.flag || flagFromCode(data.country_code);
        var location = joinLocation(data);

        flagElement.textContent = flag;
        ipElement.textContent = data.ip && data.ip !== '-' ? data.ip : '获取失败';
        locationElement.textContent = location;

        root.classList.remove('argon-ip-loading', 'argon-ip-error');
        root.style.opacity = '1';
        root.title =
            '公网出口 IPv4：' + (data.ip || '-') + '\n' +
            '国家：' + (data.country || '-') + '\n' +
            '省/州：' + (data.region || '-') + '\n' +
            '城市：' + (data.city || '-') + '\n' +
            'ISP：' + (data.isp || '-') + '\n' +
            '更新时间：' + (data.time || '-') + '\n' +
            '点击立即刷新';
    }

    function update(force) {
        if (busy)
            return;

        busy = true;
        setLoading();

        fetch(
            '/cgi-bin/argon-realtime-ip?' +
            (force ? 'force=1&' : '') +
            '_=' + Date.now(),
            {
                cache: 'no-store',
                credentials: 'same-origin'
            }
        )
        .then(function (response) {
            if (!response.ok)
                throw new Error('HTTP ' + response.status);

            return response.json();
        })
        .then(function (data) {
            render(data);
            busy = false;
        })
        .catch(function () {
            root.classList.remove('argon-ip-loading');
            root.classList.add('argon-ip-error');
            ipElement.textContent = '获取失败';
            locationElement.textContent = '点击这里重新检测';
            root.style.opacity = '1';
            root.title = '点击重新检测公网 IP 和位置';
            busy = false;
        });
    }

    root.addEventListener('click', function (event) {
        event.preventDefault();
        event.stopPropagation();
        update(true);
    });

    update(false);

    window.setInterval(function () {
        update(false);
    }, 60000);
})();
EOF

chmod 644 /www/luci-static/argon/realtime-ip.js

# ============================================================
# 6. Realtime-IP v4 visual layer
# ============================================================

cat > /www/luci-static/argon/realtime-ip-v4.css <<'EOF'
#argon-realtime-ip {
    position: relative;
    box-sizing: border-box;
    width: 224px;
    max-width: calc(100vw - 36px) !important;
    margin: 8px 0 2px !important;
    padding: 10px 12px !important;
    border: 1px solid rgba(90, 220, 255, .48);
    border-radius: 15px;
    background: linear-gradient(135deg, rgba(11, 33, 54, .82), rgba(28, 18, 58, .76));
    box-shadow: 0 10px 28px rgba(0, 0, 0, .24), inset 0 1px 0 rgba(255, 255, 255, .12);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    transition: transform .2s ease, box-shadow .2s ease, border-color .2s ease, opacity .2s ease;
}
#argon-realtime-ip:hover {
    transform: translateY(-2px);
    border-color: rgba(80, 255, 184, .78);
    box-shadow: 0 14px 34px rgba(0, 0, 0, .31), 0 0 18px rgba(0, 255, 170, .12);
}
#argon-realtime-ip::before {
    content: '';
    position: absolute;
    top: -1px;
    left: 18px;
    right: 18px;
    height: 2px;
    border-radius: 2px;
    background: linear-gradient(90deg, transparent, #35e7ff, #49ff9d, transparent);
}
#argon-realtime-address {
    color: #61ffd0 !important;
    letter-spacing: .25px;
    text-shadow: 0 0 10px rgba(72, 255, 192, .56) !important;
}
#argon-realtime-location { color: rgba(235, 248, 255, .86); }
#argon-realtime-ip.argon-ip-error { border-color: rgba(255, 95, 113, .66); }
#argon-realtime-ip.argon-ip-loading #argon-realtime-flag { animation: argon-ip-spin 1.1s linear infinite; }
@keyframes argon-ip-spin { to { transform: rotate(360deg); } }
.argon-public-ip-overview {
    overflow: hidden;
    border: 1px solid rgba(82, 196, 255, .28);
    border-radius: 16px;
    background: linear-gradient(145deg, rgba(25, 76, 112, .10), rgba(113, 53, 173, .08));
    box-shadow: 0 9px 26px rgba(0, 0, 0, .08);
}
.argon-public-ip-title {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 14px 18px;
    font-size: 16px;
    font-weight: 700;
    border-bottom: 1px solid rgba(127, 127, 127, .16);
}
.argon-public-ip-title .pulse {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    background: #35e99a;
    box-shadow: 0 0 0 0 rgba(53, 233, 154, .55);
    animation: argon-ip-pulse 1.8s infinite;
}
.argon-public-ip-overview .table { margin: 0; }
.argon-public-ip-overview .tr:nth-child(odd) { background: rgba(127, 127, 127, .035); }
.argon-public-ip-overview .td { padding-top: 11px; padding-bottom: 11px; }
@keyframes argon-ip-pulse { 70% { box-shadow: 0 0 0 9px rgba(53, 233, 154, 0); } 100% { box-shadow: 0 0 0 0 rgba(53, 233, 154, 0); } }
@media (max-width: 700px) {
    #argon-realtime-ip { width: 100%; }
    .argon-public-ip-overview .td:first-child { width: 42% !important; }
}
EOF
chmod 644 /www/luci-static/argon/realtime-ip-v4.css

# ============================================================
# 6. 在“状态 → 概览”中创建公网出口信息卡片
#    文件名 15_ 开头，使其排在“系统”之后、“内存”之前
# ============================================================

STATUS_INCLUDE_DIR="/www/luci-static/resources/view/status/include"
mkdir -p "$STATUS_INCLUDE_DIR"

cat > "$STATUS_INCLUDE_DIR/15_public_ip.js" <<'EOF'
'use strict';
'require baseclass';

function flagFromCode(code) {
    code = String(code || '').trim().toUpperCase();

    if (!/^[A-Z]{2}$/.test(code))
        return '🌐';

    return String.fromCodePoint(
        127397 + code.charCodeAt(0),
        127397 + code.charCodeAt(1)
    );
}

function text(value) {
    return value != null && value !== '' ? value : '-';
}

return baseclass.extend({
    title: _('公网出口信息'),

    load: function() {
        return fetch(
            '/cgi-bin/argon-realtime-ip?_=' + Date.now(),
            {
                cache: 'no-store',
                credentials: 'same-origin'
            }
        )
        .then(function(response) {
            if (!response.ok)
                throw new Error('HTTP ' + response.status);

            return response.json();
        })
        .catch(function() {
            return {
                ok: false,
                ip: '-',
                country: '-',
                country_code: '',
                region: '-',
                city: '-',
                isp: '-',
                time: '-'
            };
        });
    },

    render: function(data) {
        data = data || {};

        var flag = data.flag || flagFromCode(data.country_code);
        var ipNode = E('span', {
            'style': 'font-size:19px;font-weight:700;color:#00ff66;text-shadow:0 0 6px rgba(0,255,102,.55);'
        }, [ text(data.ip) ]);

        var countryNode = E('span', {}, [
            E('span', {
                'style': 'font-size:24px;vertical-align:middle;margin-right:8px;'
            }, [ flag ]),
            text(data.country),
            data.country_code ? ' (' + data.country_code + ')' : ''
        ]);

        var fields = [
            _('公网 IPv4'), ipNode,
            _('国家/地区'), countryNode,
            _('省/州'), text(data.region),
            _('城市'), text(data.city),
            _('网络运营商'), text(data.isp),
            _('更新时间'), text(data.time)
        ];

        var table = E('table', { 'class': 'table' });

        for (var i = 0; i < fields.length; i += 2) {
            table.appendChild(E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td left', 'width': '33%' }, [ fields[i] ]),
                E('td', { 'class': 'td left' }, [ fields[i + 1] ])
            ]));
        }

        return E('div', { 'class': 'argon-public-ip-overview' }, [
            E('div', { 'class': 'argon-public-ip-title' }, [
                E('span', { 'class': 'pulse' }),
                E('span', {}, [ _('实时公网出口') ])
            ]),
            table
        ]);
    }
});
EOF

chmod 644 "$STATUS_INCLUDE_DIR/15_public_ip.js"

# ============================================================
# 7. 清理旧标记区块，恢复其中原始主机名标签
# ============================================================

RESTORED="${HEADER}.restored.$$"

awk '
/ARGON_REALTIME_IP_BEGIN/ {
    inside = 1
    brand = ""
    next
}

inside && /<a[[:space:]]+class="brand"[[:space:]]+href="#">/ && /hostname/ {
    if (brand == "")
        brand = $0
    next
}

inside && /ARGON_REALTIME_IP_END/ {
    inside = 0
    if (brand != "")
        print brand
    brand = ""
    next
}

!inside {
    print
}
' "$HEADER" > "$RESTORED"

mv "$RESTORED" "$HEADER"

# ============================================================
# 8. 在 Argon 左上角主机名下方插入新版显示区
# ============================================================

TMP_FILE="${HEADER}.tmp.$$"

if ! awk '
!inserted &&
/<a[[:space:]]+class="brand"[[:space:]]+href="#">/ &&
/hostname/ {
    print "\t\t<!-- ARGON_REALTIME_IP_BEGIN -->"
    print "\t\t<link rel=\"stylesheet\" href=\"/luci-static/argon/realtime-ip-v4.css?v=4.0.0\">"
    print "\t\t<div class=\"argon-host-ip-block\" style=\"display:flex;flex:1;min-width:0;flex-direction:column;align-items:flex-start;justify-content:center;overflow:hidden;\">"
    print $0
    print "\t\t\t<div id=\"argon-realtime-ip\" style=\"max-width:215px;margin-top:2px;cursor:pointer;line-height:1.15;white-space:nowrap;overflow:hidden;\" title=\"点击刷新公网 IP 和位置\">"
    print "\t\t\t\t<div style=\"display:flex;align-items:center;max-width:215px;overflow:hidden;\">"
    print "\t\t\t\t\t<span id=\"argon-realtime-flag\" style=\"font-size:20px;margin-right:5px;flex:none;\">🌐</span>"
    print "\t\t\t\t\t<span style=\"font-size:12px;margin-right:3px;opacity:.9;flex:none;\">公网 IP：</span>"
    print "\t\t\t\t\t<span id=\"argon-realtime-address\" style=\"font-size:19px;font-weight:700;color:#00ff66;text-shadow:0 0 6px rgba(0,255,102,.65);overflow:hidden;text-overflow:ellipsis;\">检测中…</span>"
    print "\t\t\t\t</div>"
    print "\t\t\t\t<div id=\"argon-realtime-location\" style=\"max-width:215px;margin-top:2px;font-size:12px;font-weight:500;opacity:.86;overflow:hidden;text-overflow:ellipsis;\">正在查询国家和位置</div>"
    print "\t\t\t</div>"
    print "\t\t</div>"
    print "\t\t<script src=\"/luci-static/argon/realtime-ip.js?v=4.0.0\"></script>"
    print "\t\t<!-- ARGON_REALTIME_IP_END -->"

    inserted = 1
    next
}

{
    print
}

END {
    if (!inserted)
        exit 2
}
' "$HEADER" > "$TMP_FILE"; then
    rm -f "$TMP_FILE"
    cp -a "$BACKUP" "$HEADER"
    echo "[错误] 没有在模板中找到 Argon 左侧主机名元素。"
    echo "模板已自动恢复。"
    exit 1
fi

mv "$TMP_FILE" "$HEADER"

# ============================================================
# 9. 清理缓存并重启服务
# ============================================================

rm -f /tmp/argon-public-ip.json
rm -f /tmp/argon-public-ip.time
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
rm -rf /tmp/luci-templatecache

/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart

# 首次预取，避免页面第一次打开等待过久
/usr/bin/argon-public-ip >/tmp/argon-public-ip-first-run.log 2>&1 || true

echo
echo "=================================================="
echo " 安装完成"
echo "=================================================="
echo "左上角：公网 IP + 国旗 + 国家/省州/城市"
echo "系统概览：新增“公网出口信息”卡片"
echo "缓存时间：60 秒"
echo "手动刷新：点击左上角公网 IP 区域"
echo
echo "浏览器请按 Ctrl + F5 强制刷新。"
echo
echo "命令行检测："
echo "  /usr/bin/argon-public-ip --force"
echo
echo "CGI 接口检测："
echo "  wget -qO- 'http://127.0.0.1/cgi-bin/argon-realtime-ip?force=1'"
echo
echo "主题备份："
echo "  $BACKUP"
