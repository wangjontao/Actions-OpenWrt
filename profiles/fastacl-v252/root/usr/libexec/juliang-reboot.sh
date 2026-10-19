#!/bin/sh
# A detached worker; cancelling or replacing its token makes it harmless.
case "$1" in 2|60) ;; *) exit 1 ;; esac
case "$2" in ''|*[!a-f0-9-]*) exit 1 ;; esac
[ "${#2}" -eq 36 ] || exit 1
sleep "$1"
exec lua -e "require('juliang_reboot').service().fire('$2')"
