#!/bin/sh

#---------------------------------------------------------------------------------------------------------#
#Wan ETH IP and Public IP
#Get WAN Address from Router
. /lib/functions/network.sh; network_find_wan NET_IF; network_get_ipaddr WAN_ADDR "${NET_IF}";
#Get Public IP address from Internet
cip=$(curl https://ipv4.wtfismyip.com/text) > /dev/null 2>&1
#Echo to File
echo "wanip=${WAN_ADDR}" "publicip=${cip}" >/tmp/wanip.out
sleep 1

#---------------------------------------------------------------------------------------------------------#
# Run nlbw export to csv and save to file. 
nlbw -c csv -g ip,mac -o ip | tr -d '"' | tail -n +2 > /tmp/nlbwmon.out

#---------------------------------------------------------------------------------------------------------#
# Check if internet-outage.sh is running, if not start it.
if ! pgrep -f "internet-outage.sh" >/dev/null; then
    logger "internet-outage.sh is not running. Starting it now..."
    /usr/bin/internet-outage.sh &
else
    logger "internet-outage.sh is already running."
fi

#---------------------------------------------------------------------------------------------------------#
#####Run vnstat and parse output
vnstat --xml |grep -hnr "month id" | sed 's/<[^>]*>/ /g; s/2025//g; s/        //g' | cut -d " " -f2- | cut -d " " -f2- > /tmp/vnstatmonth.out
#vnstat --xml |grep -hnr "month id" | sed 's/<[^>]*>/ /g; s/2025//g; s/        //g' | cut -d " " -f2- > /tmp/monthoutput.out
#vnstat --xml |grep -hnr "day id" | sed 's/<[^>]*>/ /g; s/2025//g; s/        //g' | cut -d " " -f2- > /tmp/dayoutput.out
#vnstat --xml |grep -hnr "hour id" | sed 's/<[^>]*>/ /g; s/2025//g; s/        //g; s/  00/:00/g' | cut -d " " -f2-  > /tmp/houroutput.out
#vnstat --xml |grep -hnr "fiveminute id" | sed 's/<[^>]*>/ /g; s/2025//g; s/        //g' | cut -d " " -f2-   > /tmp/fiveoutput.out

#---------------------------------------------------------------------------------------------------------#
# Restart Netify if service is not running
if ! pgrep netifyd
then /etc/init.d/netifyd start
else
#Restart Netify is it uses high memory
if [ `top -b -n 1 | grep netify | grep -v "grep" | awk '{print $6}'| tr -d '%'` -gt 25 ];then
echo "Restarting Netify due to high memory"
/etc/init.d/netifyd restart
else
echo "Netify Memory is fine"
fi
fi
#exit 0

#---------------------------------------------------------------------------------------------------------#

