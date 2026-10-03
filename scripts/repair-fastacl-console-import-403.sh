#!/bin/sh
set -eu

TARGET="/usr/lib/lua/luci/view/juliang_fastacl/console.htm"
MARKER="JuLiangTK: FastACL import GET csrf fix"

[ -s "$TARGET" ] || { echo "[ERROR] FastACL console not found: $TARGET" >&2; exit 1; }
command -v lua >/dev/null 2>&1 || { echo "[ERROR] lua not found" >&2; exit 1; }

BACKUP="${TARGET}.bak.$(date +%Y%m%d-%H%M%S)"
cp -af "$TARGET" "$BACKUP"
echo "[INFO] Backup: $BACKUP"

if grep -q "$MARKER" "$TARGET"; then
  echo "[INFO] FastACL import HTTP 403 fix already installed"
  exit 0
fi

JFA_CONSOLE="$TARGET" lua <<'LUA'
local path = assert(os.getenv("JFA_CONSOLE"), "JFA_CONSOLE missing")
local f = assert(io.open(path, "rb"))
local s = f:read("*a")
f:close()

local old = [[      var fd=new FormData();
      fd.append('action','import');
      fd.append('chunk',text.substring(idx*chunkSize,(idx+1)*chunkSize));
      fd.append('chunk_index',idx);
      fd.append('total_chunks',total);
      fd.append('group','default');

      var x=new XMLHttpRequest();
      x.open('POST',IMPORT_API,true);
      x.onload=function(){
        if(x.status===200){
          idx++;
          importMsg('正在导入 '+idx+'/'+total+'…');
          sendNext();
        }else{
          btn.disabled=false;
          importMsg('导入失败：HTTP '+x.status,false);
        }
      };
      x.onerror=function(){
        btn.disabled=false;
        importMsg('导入失败：网络请求错误',false);
      };
      x.send(fd);]]

local new = [[      // JuLiangTK: FastACL import GET csrf fix
      // Use LuCI XHR.get like the rest of this console. The old raw POST
      // was rejected by LuCI CSRF protection with HTTP 403.
      var params={
        action:'import',
        chunk:text.substring(idx*chunkSize,(idx+1)*chunkSize),
        chunk_index:idx,
        total_chunks:total,
        group:'default'
      };
      XHR.get(IMPORT_API,params,function(x,r){
        if(x&&x.status===200&&r&&r.ok){
          idx++;
          importMsg('正在导入 '+idx+'/'+total+'…');
          sendNext();
        }else{
          btn.disabled=false;
          var why=(r&&r.error)?r.error:('HTTP '+(x?x.status:0));
          importMsg('导入失败：'+why,false);
        }
      });]]

local a,b = s:find(old,1,true)
if not a then
  error("old FastACL import POST block not found; console version unsupported")
end
s = s:sub(1,a-1) .. new .. s:sub(b+1)
s = s:gsub("var chunkSize=1000;", "var chunkSize=700;", 1)

local o = assert(io.open(path,"wb"))
o:write(s)
o:close()
LUA

if ! grep -q "$MARKER" "$TARGET"; then
  echo "[ERROR] patch marker missing, restoring backup" >&2
  cp -af "$BACKUP" "$TARGET"
  exit 1
fi

grep -q "XHR.get(IMPORT_API,params" "$TARGET" || {
  echo "[ERROR] XHR.get patch missing, restoring backup" >&2
  cp -af "$BACKUP" "$TARGET"
  exit 1
}
if grep -q "x.open('POST',IMPORT_API,true)" "$TARGET"; then
  echo "[ERROR] old POST importer still present, restoring backup" >&2
  cp -af "$BACKUP" "$TARGET"
  exit 1
fi

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] FastACL batch import HTTP 403 fix installed"
echo "[OK] Import now uses LuCI XHR.get chunk requests"
echo "[INFO] FastACL dataplane and PassWall2 proxy cores were not restarted"
echo "[INFO] Backup: $BACKUP"
