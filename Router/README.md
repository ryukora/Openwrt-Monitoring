# Router Scripts and Lua Files Repo




On the router, the following scripts and prometheus Lua files are used on the router. The routersetup.sh will copy these bash script files to /usr/bin and the lua files to the prometheus location. 

The Scripts will output "Reports" to /tmp/ location as *.out. 

The Prometheus lua files will read these "Reports.out" files and parse the data for prometheus to scrape. 

In the Scripts folder:
  >1-hour-script.sh - mainly used to restart netify
  
  >1-min-script.sh - Get your WanIP, Run VNstat monthly report, Restart Netify if service is not running
  
  >5-min-script.sh - Get your WanIP, Run VNstat monthly report, Restart Netify if service is not running
  
  >12am-script.sh - Backup vnstat.db, Remove new_device file, and if its the 1st of the month, drop vnstat DB
  
  >device-status-ping.sh -- Ping devices on network to see if they are online
  
  >new_device.sh -- Check if new devices are found on network (WIP Doesnt work yet)
  
  >packet-loss.sh -- This will monitor packetloss by pinging google 40 times a minute and gather the packetloss rate
  
  >speedtest.sh -- This is a speedtest script created by someone else, if this doesnt run its because the 3rd party speed test blocked your ip. 
  
  In the lua folder:
  >device-ping-status.lua -- will read /tmp/device-status.out and collect data

>gl-router-temp.lua -- Will read /tmp/tempstats.out (written by 15-second-script.sh) and collect data. Installed on GL.iNet devices only (force with GL_TEMP=1 / skip with GL_TEMP=0)

>netify.lua -- Will read /tmp/netify.out and collect data

>new_device.lua -- Will read /tmp/new_device.out and collect data

>packetloss.lua -- Will read /tmp/packetloss.out and collect data

>speedtest.lua -- Will read /tmp/speedtest.out and collect data

>vnstatmonth.lua -- Will read /tmp/vnstatmonth.out and collect data

>wanip.lua -- Will read /tmp/wanip.out and collect data

In the nlbw2collectd folder (per-device traffic, works with nftables / fw4):
>nlbw2collectd.lua -- copied to /usr/share/collectd-mod-lua. Reads `nlbw -c json -g ip` and sends rx (download) / tx (upload) bytes and packets per device to collectd (needs collectd-mod-lua)

>lua.conf -- copied to /etc/collectd/conf.d. Loaded because routersetup.sh sets `luci_statistics.collectd.Include='/etc/collectd/conf.d'`

In Prometheus the values show up as `collectd_nlbwmon_ipt_bytes_total{nlbwmon="nlbwmon_rx"|"nlbwmon_tx", type="<device>"}`.

In the collectd-lua folder:
>device-status.lua -- Prometheus collector for /tmp/device-status.out (copied to /usr/lib/lua/prometheus-collectors)

luci_statistics -- reference template of /etc/config/luci_statistics after routersetup.sh (see the main README, "About the template")
