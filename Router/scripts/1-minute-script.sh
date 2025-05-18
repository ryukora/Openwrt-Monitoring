#!/bin/sh

# ---------------------------------------------------------------------------------------------------------#
# Get WAN Address from Router
. /lib/functions/network.sh
network_find_wan NET_IF
network_get_ipaddr WAN_ADDR "${NET_IF}"
network_find_wan6 NET_IF6
network_get_ipaddr6 WAN_ADDR6 "${NET_IF6}"

# Trim spaces
WAN_ADDR=$(echo "$WAN_ADDR")
WAN_ADDR6=$(echo "$WAN_ADDR6")

# Get Public IP address from Internet (suppress errors)
cip4=$(curl -s https://api.ipify.org/?format=text 2>/dev/null)
cip6=$(curl -s https://api64.ipify.org?format=text 2>/dev/null)

# Ensure values are set; if empty, assign "N/A"
wan_ipv4=${WAN_ADDR:-"N/A"}
wan_ipv6=${WAN_ADDR6:-"N/A"}
public_ipv4=${cip4:-"N/A"}
public_ipv6=${cip6:-"N/A"}

# Format Output
wanip="${wan_ipv4},${wan_ipv6}"
publicip="${public_ipv4},${public_ipv6}"

# Write to File
echo "wanip=${wanip}" "publicip=${publicip}" > /tmp/wanip.out

sleep 1
#---------------------------------------------------------------------------------------------------------#
# Run nlbw export to CSV and save to a file
if command -v nlbw >/dev/null; then
    nlbw -c csv -g ip,mac -o ip | tr -d '"' | tail -n +2 > /tmp/nlbwmon.out
fi
#---------------------------------------------------------------------------------------------------------#
# Check if internet-outage.sh is running, if not, start it
if ! pgrep -f "internet-outage.sh" >/dev/null; then
    /usr/bin/internet-outage.sh &
fi
#---------------------------------------------------------------------------------------------------------#
# Run vnstat and parse the output
if command -v vnstat >/dev/null; then
    vnstat --xml | grep -hnr "month id" | sed 's/<[^>]*>//g; s/2025//g; s/        //g' | cut -d " " -f2- | cut -d " " -f2- > /tmp/vnstatmonth.out
	  #vnstat --xml |grep -hnr "month id" | sed 's/<[^>]*>/ /g; s/2025//g; s/        //g' | cut -d " " -f2- > /tmp/monthoutput.out
	  #vnstat --xml |grep -hnr "day id" | sed 's/<[^>]*>/ /g; s/2025//g; s/        //g' | cut -d " " -f2- > /tmp/dayoutput.out
	  #vnstat --xml |grep -hnr "hour id" | sed 's/<[^>]*>/ /g; s/2025//g; s/        //g; s/  00/:00/g' | cut -d " " -f2-  > /tmp/houroutput.out
	  #vnstat --xml |grep -hnr "fiveminute id" | sed 's/<[^>]*>/ /g; s/2025//g; s/        //g' | cut -d " " -f2-   > /tmp/fiveoutput.out
fi
#---------------------------------------------------------------------------------------------------------#
# Restart Netify if the service is not running or using high memory
#if ! pgrep netifyd >/dev/null; then
#    /etc/init.d/netifyd start
#else
#    # Restart Netify if memory usage exceeds 25%
#    netify_mem=$(top -b -n 1 | awk '/netify/ && !/grep/ {print $6}' | tr -d '%')
#    if [ -n "$netify_mem" ] && [ "$netify_mem" -gt 25 ]; then
#        echo "Restarting Netify due to high memory usage"
#        /etc/init.d/netifyd restart
#    fi
#fi
#---------------------------------------------------------------------------------------------------------#
