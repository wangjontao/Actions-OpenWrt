#!/bin/sh
set -eu
BACKUP=/etc/juliang-fastacl/acl-template-backup-$(date +%Y%m%d-%H%M%S)-$$
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
for app in passwall passwall2; do
  file=/usr/lib/lua/luci/view/$app/acl_ip_refresh.htm
  [ -f "$file" ] || continue
  cp -p "$file" "$BACKUP/$app.htm"
  if ! grep -q 'if not _jfa_enabled then' "$file"; then
    {
      cat <<'HEAD'
<%
local _jfa_enabled = require("luci.model.uci").cursor():get("juliang_fastacl", "main", "enabled") == "1"
if not _jfa_enabled then
%>
HEAD
      cat "$file"
    } > "$file.new"
    if lua - "$file.new" <<'CHECK'
local p=require "luci.template.parser"
local f,e=p.parse(arg[1])
assert(f,e)
CHECK
    then
      chmod 644 "$file.new"
      mv "$file.new" "$file"
    else
      rm -f "$file.new"
      echo "Template check failed: $app; original preserved"
      exit 1
    fi
  fi
  lua - "$file" <<'CHECK'
local f,e=require("luci.template.parser").parse(arg[1])
assert(f,e)
CHECK
  echo "[OK] $app ACL refresh template"
done
echo "Backup: $BACKUP"
