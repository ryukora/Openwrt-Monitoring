# Credit: [@benisai (GitHub)](https://github.com/benisai/)
  Support the original: [Openwrt-Monitoring](https://github.com/benisai/Openwrt-Monitoring)

## Intro
* This project consists of a few applications to help monitor your OpenWrt router. You will need a decent router (anything from 2- 3 years ago will work) with a core CPU, with 256mb-512mb of RAM and 128mb nand. 
  * Note: This will only work with OpenWrt 21.x (IPTables). NFTables will not be supported as IPTmon uses iptables. You can still run this project, but you won't get stats per device. 
  * Please keep in mind. I created this repo to store my project files/config somewhere so I can look back at it later (personal use). Feel free to use it, but modify the config files to your environment (IP addresses)

<br>

* I've created 2 scripts to help with the setup. 
  * serverSetup.sh will run on your Ubuntu server
  * routersetup.sh will run on your OpenWRT router.
  
<br>
 
```
* Here are some features of this project
  * Internet monitoring via pings to Google/Quad9/CloudFlare
  * Packet loss monitoring via shell script, pinging Google 40 times
  * Speedtest monitoring via shell script -- (kind of broken, hit/miss, I'll explain below)
  * DNS Stats via AdguardHome Container in Docker
  * GeoIP Map for Destination (provided by Netify logs, Check out the netify-log.sh script in the Docker folder https://github.com/ryukora/Openwrt-Monitoring/blob/main/Docker/netify-log.sh)
  * Device Traffic Panel via netify-log.sh (provided by Netify logs). Src + Dst + Port + GeoInfo 
  * Device Status (Hostname + IP + Status Online or Offline)
  * System Resources monitoring (CPU/MEM/Load/etc) via Prometheus on the Router
  * Monthly Bandwidth monitoring via VNState2 (Will clear monthly on 1st via crontab)
  * 12-hour Traffic usage (calculated by ITPMon results from Prometheus)
  * WAN Speeds via Prometheus
  * Live traffic per device (iptmon)
  * Traffic per client usage for 2hr (calculated by ITPMon results from Prometheus)
  * Ping Stats via CollectD
  * Hourly traffic usage (calculated by ITPMon results from Prometheus)
  * 7-day traffic usage (calculated by ITPMon results from Prometheus)
  * New Devices Connected to Network via Shell Script
  * Destination IP count (calculated by nat_traffic results from Prometheus)
  * Destination Port count (calculated by nat_traffic results from Prometheus)
  * NAT Traffic (calucated by nat_traffic results from prometheus)
* We need to install a few pieces of software + custom shell scripts on the router to collect this data  
```

</br>
</br>

## Software Used to Monitor Traffic
### Home Server (Ubuntu)
* Ubuntu Home Server running Docker + Docker-Compose
  Note:  I provided a Docker-Compose.yml file with all the containers needed for the project
  * Prometheus - Container to scrape and store data.
  * Grafana - Container to display the graphs. (You will need to add your Prometheus location as the data source.)
  * Loki + Promtail + Middleware - Containers used to collect and process Netify logs created by netify-log.sh
  * AdGuardHome - Container to block Ads/Porn/etc.
  * Collectd-exporter - Container to collect data from Collectd on the Router
  * Adguard-exporter - Container to collect data from AdGuardHome
  * Netify-log.sh - This will create a netcat connection to netifyd running on the router, and it will output a local JSON log 

### Router
* OpenWrt Router (21.x)
  * Custom shell scripts to collect / output data to report files 
    * 1-hour-script.sh - mainly used to restart Netify
    * 1-min-script.sh - Get your WanIP, Run VNstat monthly report, Restart Netify if service is not running
    * 5-min-script.sh - Not used at the moment
    * 12am-script.sh - Backup vnstat.db, Remove new_device file, and if its the 1st of the month, drop vnstat DB
    * device-status-ping.sh -- Ping devices on the network to see if they are online
    * new_device.sh -- Check if new devices are found on the network (WIP, doesn't work yet)
    * packet-loss.sh -- This will monitor packet loss by pinging Google 40 times a minute and gather the packet loss rate
    * speedtest.sh -- This is a speedtest script created by someone else, if this doesn't run it's because the 3rd party speed test blocked your IP.
  * Prometheus - main router monitoring (CPU, MEM, etc) with custom Prometheus Lua Files
  * Collectd - to monitor ping and export iptmon data
  * vnstat2 - to monitor monthly WAN Bandwidth usage (12am-Script.sh will check if its the 1st of the month and drop the vnstatdb)
  * iptmon - to monitor per-device usage
  * Netifyd - Netify Agent is a deep-packet inspection server that detects network protocols and applications.


</br>
</br>


![Grafana Dashboard](https://github.com/ryukora/Openwrt-Monitoring/blob/main/screenshots/dashboard-full-1.png)


</br>
</br>




## Home Server Installation (Linux)

* Clone this repo to your server. 
  ```sudo wget https://github.com/ryukora/Openwrt-Monitoring/blob/main/serverSetup.sh```
   * run 'sudo nano ./serverSetup.sh' and update the router_ip variable.
   * run 'sudo chmod +x ./serverSetup.sh'
   * run 'sudo ./serverSetup.sh'
   * This command will ask if you want to install Docker; if it's already installed, it will be skipped
   * Update the netify-logs.sh file with your router IP.

   Create Crontab config on Server (replace USER with your username for the Cronjobs)  
   run 'sudo crontab -e'  and add the line below. 
```   
   */1 * * * * /root/Openwrt-Monitoring/Docker/netify-log.sh >> /var/log/netify/netify-cron.log 2>&1
   0 * * * * find /var/log/netify/ -name "netify.log*" -size +256M -delete
   0 0 * * * find /var/log/netify/ -type f -name "netify-cron.log*" -mtime +7 -exec rm -f {} \;
```

</br>



## Router Installation (OpenWrt 21.x)
* Download the shell script to set up the router
  * ```wget https://raw.githubusercontent.com//Openwrt-Monitoring/main/routersetup.sh```
    * nano routersetup.sh
      * replace 10.1.1.25 with your Home Server IP
    * chmod +x routersetup.sh
* ```sh ./routersetup.sh```

<pre>
The routersetup.sh script will do the following:
* Install Nano, netperf (needed for speedtest.sh), openssh-sftp-server,vnstat
* Install Prometheus and CollectD
* Install iptmon, wrtbwmon, and luci-wrtbwmon
* Copy custom scripts from this git to /usr/bin/ on the router
* Copy custom LUA files from this git to /usr/lib/lua/prometheus-collectors on the router.
* Adding new_device.sh script to dhcp dnsmasq
* Adding scripts to Crontab
* Update Prometheus config to 'lan'
* Update Collectd Export IP to home server IP address
* Add iptmon to your DHCP file under the dnsmasq section
* Set your LAN interface to assign the DNS IP of your home server
* restarts services
</pre>

* Note: I removed the interface DNS as it was causing some issues if you don't have AdGuard Home running on your Docker server. If you do, please make sure to uncomment the DNS part of the script so AdGuard Home can see the hostnames of the devices. 


<br>
<br>
<br>




## Extra Configuration for OpenWRT

* Configure Collectd on the Router
  * Licu -> Statistics -> Setup ->
  * Collectd Settings:
      * Set the Data collection interval to 10 seconds
  * Network plugins:
      * Configure the Ping (1.1.1.1, 8.8.8.8, 9.9.9.9)
      * Configure the Firewall plugin (See screenshot https://github.com/ryukora/Openwrt-Monitoring/blob/main/screenshots/CollectD1-firewall.PNG)
  * Output plugins:
      * Configure Network -> Server interfaces (add your home server ip ex.10.1.1.25) (see screenshot https://github.com/ryukora/Openwrt-Monitoring/blob/main/screenshots/Collectd-output.PNG)

<br>
   
* Configure Netify.d on the Router
  * SSH into the router
  * You must add your router's IP address to the Socket section below to enable TCP sockets in the netifyd engine.
  * nano /etc/netifyd.conf
    * (replace 10.1.1.1 with your router's IP address)
      <pre>
      [socket]
      listen_path[0] = /var/run/netifyd/netifyd.sock
      listen_address[0] = 10.1.1.1    <---------Add this line, update the Router IP
      </pre>
  * Reboot Router

<br>
<br>


## Troubleshooting: 
* Run these commands manually if you cannot find the iptmon in the luci_statistics firewall. 
```
## dnsmasq configuration
	uci set dhcp.@dnsmasq[0].dhcpscript=/usr/sbin/iptmon
	
## firewall configuration
	echo '/usr/sbin/iptmon init' >> /etc/firewall.user

## luci_statistics/collectd configuration.
	uci set luci_statistics.collectd.Include='/etc/collectd/conf.d'

## Commit changes.
	uci commit

## Restart services.
 /etc/init.d/dnsmasq restart
	/etc/init.d/firewall restart
	/etc/init.d/luci_statistics restart

 rm -rf /tmp/luci-modulecache/
```

--------

Credit: I have to give credit to Matthew Helmke, I used his blog and Grafana dashboard, and I added some stuff. I can't say I'm an expert in Grafana or Prometheus (first time using Prom) https://grafana.com/blog/2021/02/09/how-i-monitor-my-openwrt-router-with-grafana-cloud-and-prometheus/



