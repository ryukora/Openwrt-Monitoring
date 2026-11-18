#!/bin/sh
# NOTE: OpenWrt has no bash by default, so this script must stay POSIX sh.
#---------------------------------------------------------------------------------------------------------#
DATE=$(date +%m-%d-%Y)
BACKUP_DIR="/etc/backup"
#BACKUP_DIR="/tmp/mountd/disk1_part1"
mkdir -p "$BACKUP_DIR"
# backup the vnstat.db (and wrtbwmon usage.db if it exists) and add a timestamp to the file
[ -f /var/lib/vnstat/vnstat.db ] && cp /var/lib/vnstat/vnstat.db "$BACKUP_DIR/vnstat.db-$DATE.bak"
[ -f /tmp/usage.db ] && cp /tmp/usage.db "$BACKUP_DIR/usage.db-$DATE.bak"
# Delete backup files older than 3 days #
find "$BACKUP_DIR" -name "*.bak" -mtime +3 -exec rm -f {} \;

#---------------------------------------------------------------------------------------------------------#
#Remove new_device file
rm -f /tmp/new_device.out
touch /tmp/new_device.out

#---------------------------------------------------------------------------------------------------------#
# Remove Internet-outage file at 12am cst
# Set the path to the log file
outage_file="/tmp/wan_monitor.log"
if [ -f "$outage_file" ]; then
  rm "$outage_file"
  touch "$outage_file"
fi

#---------------------------------------------------------------------------------------------------------#
###----If its the first of the month, drop the vnstat interface and recreate----###
#Find WAN Interface for vnstat to monitor
gateway_ip=$(ip route | awk '/default/ {print $3}')
wan_iface=$(ip route | awk -v ip="$gateway_ip" '$0~ip {print $5}')
#Get Date
bi=$(date +%d)
if [ "$bi" = "01" ] && [ -n "$wan_iface" ]
then
    vnstat --remove -i "$wan_iface" --force
    vnstat --add -i "$wan_iface"
    /etc/init.d/vnstat restart

else
    echo "It is not the 1st of the month, so vnstat will not drop the interface to recreate"
fi

#---------------------------------------------------------------------------------------------------------#
