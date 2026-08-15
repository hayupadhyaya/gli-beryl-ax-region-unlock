#!/bin/sh
# Capture every region-sensitive aspect of the running system, deterministically
# ordered so two snapshots can be diffed cleanly.
echo "##### country #####"
echo "proc:     [$(cat /proc/gl-hw-info/country_code 2>/dev/null)]"
echo "flash:    [$(dd if=/dev/mtdblock3 bs=1 skip=136 count=2 2>/dev/null)]"
echo "uci_ovr:  [$(uci -q get board_special.hardware.country_code || echo none)]"
. /lib/functions/gl_util.sh 2>/dev/null; echo "helper:   [$(get_country_code 2>/dev/null)]"

echo "##### installed packages #####"
opkg list-installed 2>/dev/null | awk '{print $1}' | sort

echo "##### init scripts + enabled state #####"
for f in /etc/init.d/*; do
  n=$(basename "$f")
  if "$f" enabled 2>/dev/null; then s=enabled; else s=disabled; fi
  echo "$n=$s"
done | sort

echo "##### running processes (names only) #####"
ps w 2>/dev/null | awk '{ $1="";$2="";$3="";$4=""; print }' | sed 's/^ *//' | sort -u

echo "##### oui-httpd rpc modules #####"
ls /usr/lib/oui-httpd/rpc/ 2>/dev/null | sort

echo "##### uci: full config dump #####"
uci show 2>/dev/null | sort

echo "##### /etc/config files present #####"
ls /etc/config/ 2>/dev/null | sort

echo "##### www menu / feature definitions #####"
ls /www/ 2>/dev/null | sort
