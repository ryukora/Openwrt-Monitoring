# Credit: [@benisai (GitHub)](https://github.com/benisai/)
  Support the original: [Openwrt-Monitoring](https://github.com/benisai/Openwrt-Monitoring)

## Intro
* This project consists of a few applications to help monitor your OpenWrt router with Grafana. You will need a decent router (anything from the last few years will work) with 256 MB-512 MB of RAM and 128 MB of flash.
* Supported OpenWrt versions:

  | OpenWrt | Package manager | Status |
  |---|---|---|
  | **25.12.x** and newer (latest) | `apk` | Supported |
  | **24.10.x** | `opkg` | Supported |
  | 23.05 / 22.03 | `opkg` | Should work, not tested |
  | 21.02 and older | `opkg` | Not supported anymore |

  `routersetup.sh` detects the package manager by itself, so the installation steps are the same for 24.x and 25.x.
* OpenWrt 22.03 and newer use **nftables (fw4)**. The old iptables-based tools (iptmon, wrtbwmon, the collectd *Firewall* plugin) do not work there.
  Per-device traffic now comes from **nlbwmon** (official OpenWrt package) through `nlbw2collectd`.
* Please keep in mind: I created this repo to store my project files and config so I can look back on them later (personal use). Feel free to use it.

<br>

* There are 2 scripts to help with the setup:
  * `serverSetup.sh` runs on your Linux Home Server (Ubuntu/Debian with Docker)
  * `routersetup.sh` runs on your OpenWrt router

<br>

```
* Here are some features of this project
  * Internet monitoring via pings to Google/Quad9/CloudFlare (collectd ping)
  * Packet loss monitoring via shell script, pinging Google 40 times
  * Speedtest monitoring via shell script -- (kind of broken, hit/miss, I'll explain below)
  * DNS Stats via AdguardHome Container in Docker
  * GeoIP Map for Destination (provided by Netify logs, see Docker/netify-log.sh)
  * Device Traffic Panel via netify-log.sh (provided by Netify logs). Src + Dst + Port + GeoInfo
  * Device Status (Hostname + IP + Status Online or Offline)
  * System Resources monitoring (CPU/MEM/Load/etc) via Prometheus on the Router
  * Monthly Bandwidth monitoring via vnStat2 (cleared monthly on the 1st via crontab)
  * WAN Speeds via Prometheus
  * Live traffic per device (nlbwmon -> collectd)
  * Traffic per client for the last 2 hours (nlbwmon -> collectd)
  * New Devices Connected to Network via hotplug script
  * Destination IP / Port count and NAT Traffic (nat_traffic collector in Prometheus)
```

<br>

## Software Used to Monitor Traffic
### Home Server (Linux)
* A Linux Home Server running Docker + Docker Compose. `Docker/docker-compose.yml` has all the containers needed:
  * Prometheus - scrapes and stores the data
  * Grafana - displays the graphs (add Prometheus as the data source)
  * Loki + Promtail - collect and process Netify logs created by `netify-log.sh`
  * AdGuardHome (optional, `docker-compose-extras.yml`) - blocks Ads/etc.
  * collectd-exporter - receives collectd data from the router on **udp/25826** and exposes it to Prometheus
  * Adguard-exporter - collects data from AdGuardHome
  * `netify-log.sh` - opens a connection to netifyd on the router and writes a local JSON log

### Router (OpenWrt 24.10 / 25.12+)
* Custom shell scripts (in `/usr/bin`) that write report files to `/tmp/*.out`:
  * `1-hour-script.sh` - restarts Netify
  * `1-minute-script.sh` - WAN/public IP, vnStat monthly report, nlbwmon CSV, starts the internet outage monitor
  * `5-minute-script.sh` - not used at the moment
  * `12am-script.sh` - backs up vnstat.db, clears the new device file, and on the 1st of the month resets vnStat
  * `15-second-script.sh` - client list (DHCP + ARP), also published at `http://<router-ip>/clientlist.html`
  * `device-status-ping.sh` - pings devices on the network to see if they are online
  * `new_device.sh` / `99-new-device` (hotplug) - detects new devices on the network
  * `packet-loss.sh` - pings Google 40 times a minute and records the packet loss
  * `speedtest.sh` - netperf speed test (if it doesn't run, the third-party server probably blocked your IP)
* Prometheus (`prometheus-node-exporter-lua`, port 9100) - CPU, memory, network, etc. plus the custom Lua collectors in `Router/lua`
* collectd (`luci-app-statistics`) - ping, interfaces, DHCP leases and per-device traffic, sent to the Home Server
* nlbwmon - per-device traffic accounting (works with nftables)
* vnStat2 - monthly WAN bandwidth usage
* Netifyd - deep-packet inspection agent that detects network protocols and applications

<br>

![Grafana Dashboard](https://github.com/ryukora/Openwrt-Monitoring/blob/main/screenshots/dashboard-full-1.png)

<br>

## Which IP is which?

Two machines are involved. Don't mix them up, this is the most common mistake:

| Name | What it is | Example | Where you enter it |
|---|---|---|---|
| **Router IP** | The LAN IP of your OpenWrt router (the IP you open LuCI with) | `192.168.1.1` | `serverSetup.sh` |
| **Home Server IP** | The Linux machine that runs Docker (Prometheus, Grafana, collectd-exporter) | `192.168.1.10` | `routersetup.sh` |

If you enter the **router's own IP** as the Home Server IP, collectd sends its data back to the router and nothing shows up in Grafana. `routersetup.sh` now warns you when you do this.

<br>

## Home Server Installation (Linux)

* Download and run the server script:
  ```
  wget https://raw.githubusercontent.com/ryukora/Openwrt-Monitoring/main/serverSetup.sh
  chmod +x ./serverSetup.sh
  sudo ./serverSetup.sh
  ```
  * It asks for your **Router IP** and writes it into `Docker/prometheus.yml` and `Docker/netify-log.sh`
  * It asks if you want to install Docker; if it's already installed, that step is skipped
  * It creates the netify cron job in `/etc/cron.d/netify-log-cronjob`
  * For `(Y/n)` questions, pressing **Enter** means **Yes**. For `(y/N)` questions, Enter means **No**

* Optional log cleanup cron jobs (`sudo crontab -e`):
  ```
  0 * * * * find /var/log/netify/ -name "netify.log*" -size +256M -delete
  0 0 * * * find /var/log/netify/ -type f -name "netify-cron.log*" -mtime +7 -exec rm -f {} \;
  ```
* Import `OpenWRT-Dashboard-new_2025-5-18.json` into Grafana.

<br>

## Router Installation (OpenWrt 24.10 with opkg, 25.12+ with apk)

The steps are the same for both versions. SSH into the router as root:

```
wget https://raw.githubusercontent.com/ryukora/Openwrt-Monitoring/main/routersetup.sh
sh ./routersetup.sh
```

The script asks for one thing only: the **Home Server IP** (see [Which IP is which?](#which-ip-is-which)).
At `Continue? (Y/n)` you can just press **Enter** (= Yes).

Non-interactive usage:
```
sh ./routersetup.sh 192.168.1.10        # Home Server IP as argument
sh ./routersetup.sh 192.168.1.10 -y     # also skip the confirmation
```

The LAN interface does not have to be called `lan`. The script asks the router which of its own addresses it uses to reach the Home Server (`ip route get <home-server-ip>`) and uses the interface that has that address (for example `vlan10_lan` on `br-lan.10`). It never picks an interface in the `wan` firewall zone. If detection fails, set the name yourself (list the names with `ubus list network.interface.*`):
```
LAN_INTERFACE=vlan10_lan sh ./routersetup.sh 192.168.1.10
```

You can run the script again at any time, for example to change the Home Server IP or to repair the configuration. It does not create duplicate cron jobs or duplicate collectd servers.

<pre>
routersetup.sh does the following:
* Detects OpenWrt version and package manager (apk on 25.12+, opkg on 24.10)
* Installs: curl, netperf, nlbwmon, vnstat2, netifyd, openssh-sftp-server,
  collectd + modules (rrdtool, network, ping, dhcpleases, lua, ...), luci-app-statistics,
  prometheus-node-exporter-lua + extra collectors
* Copies the custom scripts to /usr/bin and the Lua collectors to /usr/lib/lua/prometheus-collectors
* Installs nlbw2collectd (per-device traffic from nlbwmon into collectd)
* Adds the scripts to crontab
* Detects the LAN interface (any name, e.g. lan, vlan10_lan) and sets the Prometheus exporter
  to listen on it (port 9100)
* Configures collectd with uci (no manual LuCI setup needed):
    - data interval 10 seconds
    - Network output -> Home Server IP, udp/25826
    - Ping 1.1.1.1, 8.8.8.8, 9.9.9.9
    - DHCP leases, RRDtool (LuCI graphs), include /etc/collectd/conf.d
    - Firewall (iptables) plugin disabled (not usable with nftables)
* Disables any enabled collectd plugin whose collectd-mod-* package is missing
  (otherwise collectd refuses to start)
* Tests the collectd configuration before restarting it
* Adds the WAN device to vnStat, sets nlbwmon refresh to 10s
* Sets netifyd to listen on the router LAN IP (for netify-log.sh), adds a [socket] section if missing
* Restarts the services and prints a validation summary
* Backs up changed configs as *.bak.&lt;date&gt;
</pre>

After the script, open **LuCI -> Statistics -> Graphs**. Graphs appear after about one minute. A reboot is recommended.

### Upgrading the router (24.10 -> 25.12)
A sysupgrade does not keep extra packages. After upgrading, just run `routersetup.sh` again. Your config files are kept, and the script installs the packages with `apk`.

<br>

## About the template (`Router/luci_statistics`)

Older versions of `routersetup.sh` asked two questions:

```
Enter Template Home Server IP currently used in configs:
Enter Home Server IP Address:
```

The "template IP" was the **example IP that was written in the config file** (the old template used `10.0.5.5`). The script searched for that IP and replaced it with your Home Server IP. But the script never copied the template to the router, so on a fresh router there was nothing to replace. That is why you got `[WARN] Home Server IP not found in luci_statistics` and collectd never sent anything.

**The new script does not need a template IP.** It writes the settings directly with `uci` and asks only for the Home Server IP.

`Router/luci_statistics` is still in the repo as a **reference**: it shows how `/etc/config/luci_statistics` looks after `routersetup.sh` on OpenWrt 24.10 / 25.12. It is built from the OpenWrt default config plus the changes made by the script.

| Setting in the template | Value | Why |
|---|---|---|
| `collectd.Interval` | `10` | 10-second data |
| `collectd.Include` | `/etc/collectd/conf.d` | loads `lua.conf` (nlbw2collectd) |
| `collectd_rrdtool.enable` | `1` | needed for LuCI -> Statistics -> Graphs |
| `collectd_network.enable` + `collectd_network_server.host` | `1` + `10.0.5.5` | **example** Home Server IP, port `25826` |
| `collectd_ping` | `1.1.1.1 8.8.8.8 9.9.9.9` | Internet Connection / Network Health panels |
| `collectd_dhcpleases.enable` | `1` | DHCP leases count |
| `collectd_iptables.enable` | `0` | Firewall plugin, not usable with nftables |

You normally don't need it. If you want to use it by hand anyway:

```
cp /etc/config/luci_statistics /etc/config/luci_statistics.bak
wget -O /etc/config/luci_statistics https://raw.githubusercontent.com/ryukora/Openwrt-Monitoring/main/Router/luci_statistics
sed -i 's/10\.0\.5\.5/<YOUR-HOME-SERVER-IP>/' /etc/config/luci_statistics
/etc/init.d/luci_statistics restart
```

Make sure every plugin enabled in it has its package installed (`collectd-mod-ping`, `collectd-mod-dhcpleases`, `collectd-mod-lua`, ...), otherwise collectd does not start.

<br>

## Extra Configuration for OpenWrt

`routersetup.sh` now does all of this automatically. This section is only for checking or doing it by hand.

* **collectd** (LuCI -> Statistics -> Setup)
  * Collectd Settings: Data collection interval **10** seconds
  * Network plugins: **Ping** 1.1.1.1, 8.8.8.8, 9.9.9.9
  * Output plugins: **Network** -> Server interfaces -> your **Home Server IP**, port 25826 (see [screenshot](https://github.com/ryukora/Openwrt-Monitoring/blob/main/screenshots/Collectd-output.PNG))
  * Output plugins: **RRDTool** enabled (otherwise LuCI shows "No RRD data found")
  * **Do NOT configure the Firewall plugin** on OpenWrt 22.03+ (24.10, 25.12). It reads iptables rules, and fw4 uses nftables, so LuCI shows `TypeError: Cannot convert undefined or null to object` and there is nothing to monitor. The old screenshot `CollectD1-firewall.PNG` is for OpenWrt 21.02 only. Per-device traffic comes from nlbwmon now.

* **netifyd** (done by the script when the LAN interface is detected)
  * `netify-log.sh` on the Home Server connects to netifyd on the router, so netifyd must listen on the router's LAN IP:
    <pre>
    [socket]
    listen_address[0] = 192.168.1.1    &lt;--- your Router LAN IP
    listen_path[0] = /var/run/netifyd/netifyd.sock
    </pre>
  * `/etc/init.d/netifyd restart`

<br>

## Check that it works

On the router:
```
/etc/init.d/collectd status              # running
logread -e collectd                      # no "Could not find plugin" / "Parsing the config file failed"
ls /tmp/rrd/*/                           # one folder per plugin (ping, interface, nlbwmon, ...)
uci show luci_statistics | grep network_server   # host = Home Server IP
wget -qO- http://127.0.0.1:9100/metrics | head   # Prometheus exporter
```

On the Home Server:
```
curl -s http://localhost:9103/metrics | grep collectd_ping     # collectd data arrived
curl -s http://localhost:9103/metrics | grep collectd_nlbwmon  # per-device traffic arrived
```

<br>

## Troubleshooting

**`Continue? (Y/n)` -> pressed Enter -> "Setup cancelled."**
Fixed. Enter now means Yes for every `(Y/n)` question, in both scripts.

**`[WARN] Home Server IP not found in luci_statistics`**
From the old template-IP logic (see [About the template](#about-the-template-routerluci_statistics)). Download the new `routersetup.sh` and run it again.

**LuCI -> Statistics -> Graphs: "No RRD data found"**
collectd is not running or not writing RRD files. Usual causes:
* A plugin is enabled in LuCI but its `collectd-mod-*` package is not installed (for example the Firewall plugin without `collectd-mod-iptables`). collectd then stops with `Parsing the config file failed!` and procd keeps restarting it.
* `/etc/collectd/conf.d/collectd.conf` from an older version of this repo points to a Lua file that does not exist. The new script deletes it.
* RRDTool output plugin disabled.

Fix: revert any unsaved LuCI changes (top of the page: *UNSAVED CHANGES* -> Revert), then run `routersetup.sh` again. It repairs all of the above and tests the collectd config. Check with `logread -e collectd`.

**LuCI Firewall plugin: `TypeError: Cannot convert undefined or null to object`**
Expected on OpenWrt 22.03+ (nftables). Leave the Firewall plugin disabled. See [Extra Configuration](#extra-configuration-for-openwrt).

**`Command failed: Not found` / `cat: can't open '/var/run/wrtbwmon.pid'` / `sh: you need to specify whom to kill` during setup**
From the old script restarting wrtbwmon (iptables-based, doesn't work on nftables). wrtbwmon is not installed by the new script anymore. To remove an old install on 24.10: `opkg remove luci-app-wrtbwmon wrtbwmon; rm -f /usr/sbin/wrtbwmon` (on 25.12 only `rm -f /usr/sbin/wrtbwmon` is needed).

**`udhcpc: started ... no lease, failing` during setup**
Harmless. dnsmasq checks at restart whether another DHCP server exists on the LAN. "no lease" means there is none, which is good.

**Per-device traffic panels are empty**
* `logread -e nlbw` and `nlbw -c json -g ip` on the router must show data
* Only devices in the DHCP leases / static DHCP hosts are reported
* The panels use `collectd_nlbwmon_ipt_bytes_total`. Re-import the dashboard JSON from this repo if you still have the old iptmon queries (`collectd_iptables_ipt_bytes_total`)

**`[WARN] Prometheus exporter is NOT running` / `Router LAN IP : unknown`**
The LAN interface was not found (older script versions assumed it is called `lan`). The exporter's `listen_interface` must be an existing **logical** interface name from `/etc/config/network`, otherwise it never starts (`logread -e prometheus` shows "defering start until listen interface ... becomes ready"). Run the new `routersetup.sh` again, or set it yourself:
```
ubus list network.interface.*          # e.g. network.interface.vlan10_lan
LAN_INTERFACE=vlan10_lan sh ./routersetup.sh <home-server-ip>
```

**Prometheus has no router data**
`uci get prometheus-node-exporter-lua.main.listen_interface` must be your LAN interface, `wget -qO- http://<router-ip>:9100/metrics` must work, and the Router IP in `Docker/prometheus.yml` must be correct.

<br>

--------

Credit: I used Matthew Helmke's blog and Grafana dashboard, adding some updates. I can't say I'm an expert in Grafana or Prometheus (first time using Prom) https://grafana.com/blog/2021/02/09/how-i-monitor-my-openwrt-router-with-grafana-cloud-and-prometheus/
