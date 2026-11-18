#!/bin/sh
#
# OpenWrt Monitoring - router setup
# https://github.com/ryukora/Openwrt-Monitoring
#
# Supports:
#   OpenWrt 24.10.x            (opkg)
#   OpenWrt 25.12.x and newer  (apk)
#
# Usage:
#   sh ./routersetup.sh                    # interactive, asks for the Home Server IP
#   sh ./routersetup.sh 192.168.1.10       # Home Server IP as argument
#   sh ./routersetup.sh 192.168.1.10 -y    # no confirmation prompt
#
# "Home Server" = the Linux machine that runs Docker (Prometheus, Grafana,
# collectd-exporter). It is NOT the router's own IP.
#
# Safe to run again (for example to change the Home Server IP).

REPO_BASE="https://raw.githubusercontent.com/ryukora/Openwrt-Monitoring/main"
COLLECTD_PORT="25826"
PING_HOSTS="1.1.1.1 8.8.8.8 9.9.9.9"
BACKUP_DATE="$(date +%Y%m%d-%H%M%S)"

WARNINGS=0

info()  { echo "$*"; }
ok()    { echo "[OK]   $*"; }
warn()  { echo "[WARN] $*"; WARNINGS=$((WARNINGS + 1)); }
die()   { echo "[FAIL] $*"; exit 1; }

echo "========================================="
echo " OpenWrt Monitoring Router Setup"
echo "========================================="
echo ""

[ "$(id -u)" = "0" ] || die "Run this script as root."
command -v uci >/dev/null 2>&1 || die "uci not found. This script only runs on OpenWrt."

# ------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------

HOMESERVER=""
ASSUME_YES=0

for ARG in "$@"; do
    case "$ARG" in
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help)
            sed -n '2,19p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) HOMESERVER="$ARG" ;;
    esac
done

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

is_ipv4() {
    echo "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^(0|[1-9][0-9]?[0-9]?)$/ || $i + 0 > 255) exit 1
            }
        }
    '
}

# Returns 0 when the answer means "yes". Empty answer = default yes.
answer_is_yes() {
    case "$1" in
        ""|[Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# Router's own IPv4 addresses (to catch "Home Server IP = router IP")
router_ipv4_list() {
    ip -4 -o addr show 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }'
}

download_file() {
    URL="$1"
    DEST="$2"
    TMP="${DEST}.download.$$"

    echo "Downloading: $DEST"

    if ! wget -q -O "$TMP" "$URL"; then
        rm -f "$TMP"
        die "Failed downloading $URL"
    fi

    if [ ! -s "$TMP" ]; then
        rm -f "$TMP"
        die "Downloaded file is empty: $URL"
    fi

    mv -f "$TMP" "$DEST"
}

add_cron() {
    ENTRY="$1"

    crontab -l 2>/dev/null | grep -Fxq "$ENTRY" && return 0

    (
        crontab -l 2>/dev/null
        echo "$ENTRY"
    ) | crontab -
}

backup_file() {
    [ -f "$1" ] && cp -p "$1" "$1.bak.$BACKUP_DATE"
}

# ------------------------------------------------------------------------------
# Home Server IP
# ------------------------------------------------------------------------------

ROUTER_IPS="$(router_ipv4_list)"

if [ -n "$HOMESERVER" ] && ! is_ipv4 "$HOMESERVER"; then
    die "Invalid IPv4 address: $HOMESERVER"
fi

while [ -z "$HOMESERVER" ]; do
    echo "Home Server = the Linux machine running Docker (Prometheus/Grafana/collectd-exporter)."
    echo "It is NOT this router's IP."
    printf "Enter Home Server IP Address: "
    read -r HOMESERVER || die "No input (run the script with: sh ./routersetup.sh <home-server-ip>)"

    if ! is_ipv4 "$HOMESERVER"; then
        echo "Invalid IPv4 address."
        HOMESERVER=""
    fi
done

if echo "$ROUTER_IPS" | grep -Fxq "$HOMESERVER"; then
    echo ""
    echo "WARNING: $HOMESERVER is an IP address of THIS router."
    echo "The Home Server must be the Linux/Docker machine, otherwise"
    echo "collectd will send its data to the router itself and nothing arrives in Grafana."
    if [ "$ASSUME_YES" = "1" ]; then
        die "Refusing to continue with -y. Use the Home Server IP."
    fi
    printf "Use %s anyway? (y/N): " "$HOMESERVER"
    read -r USE_ANYWAY
    case "$USE_ANYWAY" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *) echo "Setup cancelled."; exit 0 ;;
    esac
fi

echo ""
echo "Home Server IP : $HOMESERVER"
echo "collectd       : $HOMESERVER:$COLLECTD_PORT (udp)"
echo ""

if [ "$ASSUME_YES" != "1" ]; then
    printf "Continue? (Y/n): "
    read -r CONTINUE_SETUP
    if ! answer_is_yes "$CONTINUE_SETUP"; then
        echo "Setup cancelled."
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# OpenWrt version & package manager
# ------------------------------------------------------------------------------

OWRT_RELEASE="unknown"
if [ -f /etc/openwrt_release ]; then
    . /etc/openwrt_release
    OWRT_RELEASE="${DISTRIB_RELEASE:-unknown}"
fi

# OpenWrt 25.12+ uses apk, 24.10 and older use opkg.
# Prefer apk when both exist (opkg can be left over on upgraded systems).
if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER="opkg"
else
    die "No supported package manager found (apk or opkg)."
fi

echo ""
info "OpenWrt release : $OWRT_RELEASE"
info "Package manager : $PKG_MANAGER"

pkg_update() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk update
    else
        opkg update
    fi
}

pkg_installed() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk info -e "$1" >/dev/null 2>&1
    else
        opkg status "$1" 2>/dev/null | grep -q '^Status:.* installed'
    fi
}

pkg_install() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk add "$1"
    else
        opkg install "$1"
    fi
}

# ------------------------------------------------------------------------------
# Internet & DNS check
# ------------------------------------------------------------------------------

echo ""
echo "Checking DNS resolution..."
nslookup raw.githubusercontent.com >/dev/null 2>&1 || die "DNS resolution failed. Check the router's DNS / WAN."
echo "DNS resolution OK."

if ! ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
    warn "Ping to 1.1.1.1 failed (ICMP may be blocked). Continuing."
fi

# ------------------------------------------------------------------------------
# Packages
# ------------------------------------------------------------------------------

echo ""
echo "Updating package lists..."
pkg_update || die "Package list update failed."

# Package names are identical for opkg (24.10) and apk (25.12).
SOFTWARE="
curl
luci-lib-jsonc
netperf
nlbwmon
luci-app-nlbwmon
openssh-sftp-server
vnstat2
vnstati2
luci-app-vnstat2
netifyd
collectd
collectd-mod-rrdtool
collectd-mod-network
collectd-mod-interface
collectd-mod-cpu
collectd-mod-load
collectd-mod-memory
collectd-mod-ping
collectd-mod-dhcpleases
collectd-mod-lua
luci-app-statistics
prometheus-node-exporter-lua
prometheus-node-exporter-lua-nat_traffic
prometheus-node-exporter-lua-netstat
prometheus-node-exporter-lua-openwrt
prometheus-node-exporter-lua-uci_dhcp_host
"

FAILED_PKGS=""

echo ""
echo "Installing packages..."
for PKG in $SOFTWARE; do
    if pkg_installed "$PKG"; then
        echo "  $PKG already installed"
        continue
    fi

    echo "  Installing $PKG"
    if ! pkg_install "$PKG"; then
        FAILED_PKGS="$FAILED_PKGS $PKG"
        warn "Failed installing $PKG"
    fi
done

# ------------------------------------------------------------------------------
# Required directories
# ------------------------------------------------------------------------------

mkdir -p /etc/collectd/conf.d
mkdir -p /usr/share/collectd-mod-lua
mkdir -p /usr/lib/lua/prometheus-collectors
mkdir -p /etc/hotplug.d/dhcp
mkdir -p /etc/profile.d

cat << "EOF" > /etc/profile.d/alias.sh
alias cls="clear"
EOF

# ------------------------------------------------------------------------------
# Clean up files from older versions of this script
# ------------------------------------------------------------------------------

# Old collectd.conf pointed to a non-existing Lua script and made collectd
# exit with "Parsing the config file failed!" once conf.d was included.
rm -f /etc/collectd/conf.d/collectd.conf

# Old versions set dnsmasq's dhcpscript to new_device.sh. dnsmasq already
# fires the hotplug event used by /etc/hotplug.d/dhcp/99-new-device,
# and new_device.sh runs from cron.
DNSMASQ_CHANGED=0
if [ "$(uci -q get dhcp.@dnsmasq[0].dhcpscript)" = "/usr/bin/new_device.sh" ]; then
    uci -q delete dhcp.@dnsmasq[0].dhcpscript
    uci commit dhcp
    DNSMASQ_CHANGED=1
    echo "Removed old dnsmasq dhcpscript (new_device.sh)."
fi

# ------------------------------------------------------------------------------
# nlbw2collectd (per-device traffic: nlbwmon -> collectd)
# ------------------------------------------------------------------------------

echo ""
echo "Installing nlbw2collectd..."

download_file \
    "${REPO_BASE}/Router/nlbw2collectd/lua.conf" \
    "/etc/collectd/conf.d/lua.conf"

download_file \
    "${REPO_BASE}/Router/nlbw2collectd/nlbw2collectd.lua" \
    "/usr/share/collectd-mod-lua/nlbw2collectd.lua"

if [ -f /etc/config/nlbwmon ]; then
    uci -q set nlbwmon.@nlbwmon[0].refresh_interval='10s'
    uci commit nlbwmon
fi

# ------------------------------------------------------------------------------
# Scripts
# ------------------------------------------------------------------------------

echo ""
echo "Installing scripts..."

for SCRIPT in \
    speedtest.sh \
    15-second-script.sh \
    1-minute-script.sh \
    1-hour-script.sh \
    5-minute-script.sh \
    12am-script.sh \
    device-status-ping.sh \
    packet-loss.sh \
    new_device.sh \
    internet-outage.sh
do
    download_file "${REPO_BASE}/Router/scripts/${SCRIPT}" "/usr/bin/${SCRIPT}"
    chmod +x "/usr/bin/${SCRIPT}"
done

download_file \
    "${REPO_BASE}/Router/scripts/99-new-device" \
    "/etc/hotplug.d/dhcp/99-new-device"

chmod +x /etc/hotplug.d/dhcp/99-new-device

# ------------------------------------------------------------------------------
# Prometheus Lua collectors
# ------------------------------------------------------------------------------

echo ""
echo "Installing Prometheus Lua collectors..."

for COLLECTOR in \
    nat_traffic.lua \
    speedtest.lua \
    wanip.lua \
    packetloss.lua \
    new_device.lua \
    vnstatmonth.lua \
    gl-router-temp.lua \
    internet-outage.lua \
    dnsmasq.lua \
    uci_dhcp_host.lua
do
    download_file \
        "${REPO_BASE}/Router/lua/${COLLECTOR}" \
        "/usr/lib/lua/prometheus-collectors/${COLLECTOR}"
done

download_file \
    "${REPO_BASE}/Router/collectd-lua/device-status.lua" \
    "/usr/lib/lua/prometheus-collectors/device-status.lua"

# ------------------------------------------------------------------------------
# Cron jobs
# ------------------------------------------------------------------------------

echo ""
echo "Configuring cron jobs..."

add_cron "0 */8 * * * /usr/bin/speedtest.sh"
add_cron "10 6 * * * rm -rf /tmp/speedtest.out"

add_cron "1 0 * * * /usr/bin/12am-script.sh"

add_cron "0 * * * * /usr/bin/1-hour-script.sh"

add_cron "*/1 * * * * /usr/bin/1-minute-script.sh"
add_cron "*/5 * * * * /usr/bin/5-minute-script.sh"

add_cron "* * * * * /usr/bin/15-second-script.sh"
add_cron "* * * * * sleep 15; /usr/bin/15-second-script.sh"
add_cron "* * * * * sleep 30; /usr/bin/15-second-script.sh"
add_cron "* * * * * sleep 45; /usr/bin/15-second-script.sh"

add_cron "*/1 * * * * /usr/bin/device-status-ping.sh"
add_cron "*/1 * * * * /usr/bin/new_device.sh"
add_cron "*/1 * * * * /usr/bin/packet-loss.sh"

# ------------------------------------------------------------------------------
# vnStat (monthly WAN usage)
# ------------------------------------------------------------------------------

. /lib/functions/network.sh

WAN_IF=""
WAN_DEV=""
network_find_wan WAN_IF
[ -n "$WAN_IF" ] && network_get_device WAN_DEV "$WAN_IF"

if [ -f /etc/config/vnstat ]; then
    # OpenWrt's vnstatd runs with --noadd, so the WAN device must be listed in uci.
    if [ -n "$WAN_DEV" ]; then
        if ! uci -q get vnstat.@vnstat[0].interface | tr ' ' '\n' | grep -Fxq "$WAN_DEV"; then
            uci -q add_list vnstat.@vnstat[0].interface="$WAN_DEV"
            uci commit vnstat
        fi
        ok "vnStat monitors WAN device $WAN_DEV"
    else
        warn "WAN device not found. Add it later: uci add_list vnstat.@vnstat[0].interface=<wan-device>; uci commit vnstat"
    fi
fi

# GL.iNet routers with USB storage: keep the vnStat database on the disk
VNSTAT_MOUNT="/tmp/mountd/disk1_part1"
if [ -d "$VNSTAT_MOUNT" ] && [ -f /etc/vnstat.conf ]; then
    backup_file /etc/vnstat.conf
    mkdir -p "$VNSTAT_MOUNT/vnstat"
    sed -i 's/^;DatabaseDir /DatabaseDir /' /etc/vnstat.conf
    sed -i "s,/var/lib/vnstat,$VNSTAT_MOUNT/vnstat,g" /etc/vnstat.conf
fi

# ------------------------------------------------------------------------------
# Prometheus node exporter: listen on LAN
# ------------------------------------------------------------------------------

if [ -f /etc/config/prometheus-node-exporter-lua ]; then
    backup_file /etc/config/prometheus-node-exporter-lua
    uci set prometheus-node-exporter-lua.main=prometheus-node-exporter-lua
    uci set prometheus-node-exporter-lua.main.listen_interface='lan'
    uci -q get prometheus-node-exporter-lua.main.listen_port >/dev/null || \
        uci set prometheus-node-exporter-lua.main.listen_port='9100'
    uci commit prometheus-node-exporter-lua
fi

# ------------------------------------------------------------------------------
# netifyd: open the TCP socket on the router's LAN IP (used by netify-log.sh)
# ------------------------------------------------------------------------------

LAN_IP=""
network_get_ipaddr LAN_IP lan
NETIFYD_CONF="/etc/netifyd.conf"

if [ -n "$LAN_IP" ] && [ -f "$NETIFYD_CONF" ] && grep -q '^\[socket\]' "$NETIFYD_CONF"; then
    backup_file "$NETIFYD_CONF"
    if grep -q '^[[:space:]]*listen_address\[0\][[:space:]]*=' "$NETIFYD_CONF"; then
        # replace the existing entry
        awk -v ip="$LAN_IP" '
            /^[[:space:]]*listen_address\[0\][[:space:]]*=/ { print "listen_address[0] = " ip; next }
            { print }
        ' "$NETIFYD_CONF" > "$NETIFYD_CONF.tmp.$$"
    else
        # add it right below the [socket] header
        awk -v ip="$LAN_IP" '
            { print }
            /^\[socket\]/ { print "listen_address[0] = " ip }
        ' "$NETIFYD_CONF" > "$NETIFYD_CONF.tmp.$$"
    fi
    mv -f "$NETIFYD_CONF.tmp.$$" "$NETIFYD_CONF"
    ok "netifyd listens on $LAN_IP"
else
    warn "netifyd socket not configured automatically. See README (Configure netifyd)."
fi

# ------------------------------------------------------------------------------
# collectd / LuCI Statistics (uci, no template IP needed)
# ------------------------------------------------------------------------------

echo ""
echo "Configuring collectd (luci_statistics)..."

if [ ! -f /etc/config/luci_statistics ]; then
    die "/etc/config/luci_statistics not found. Is luci-app-statistics installed?"
fi

backup_file /etc/config/luci_statistics

LS="luci_statistics"

# Global settings
uci set $LS.collectd=statistics
uci set $LS.collectd.Interval='10'
uci set $LS.collectd.Include='/etc/collectd/conf.d'

# RRDtool output: needed for the graphs in LuCI -> Statistics -> Graphs
uci set $LS.collectd_rrdtool=statistics
uci set $LS.collectd_rrdtool.enable='1'
uci -q get $LS.collectd_rrdtool.DataDir >/dev/null || uci set $LS.collectd_rrdtool.DataDir='/tmp/rrd'
# Older versions of this script wrote "5minute 15minute ..." here.
# LuCI reads "minute" as "month", so put the default back.
case "$(uci -q get $LS.collectd_rrdtool.RRATimespans)" in
    ""|*minute*) uci set $LS.collectd_rrdtool.RRATimespans='2hour 1day 1week 1month 1year' ;;
esac

# Network output: send everything to collectd-exporter on the Home Server
uci set $LS.collectd_network=statistics
uci set $LS.collectd_network.enable='1'
while uci -q delete $LS.@collectd_network_server[0]; do :; done
NET_SERVER="$(uci add $LS collectd_network_server)"
uci set $LS.$NET_SERVER.host="$HOMESERVER"
uci set $LS.$NET_SERVER.port="$COLLECTD_PORT"

# Ping (Internet Connection / Network Health panels)
uci set $LS.collectd_ping=statistics
uci set $LS.collectd_ping.enable='1'
uci set $LS.collectd_ping.TTL='127'
uci set $LS.collectd_ping.Interval='15'
uci set $LS.collectd_ping.AddressFamily='any'
uci -q delete $LS.collectd_ping.Hosts
for HOST in $PING_HOSTS; do
    uci add_list $LS.collectd_ping.Hosts="$HOST"
done

# DHCP leases count
uci set $LS.collectd_dhcpleases=statistics
uci set $LS.collectd_dhcpleases.enable='1'
uci set $LS.collectd_dhcpleases.Path='/tmp/dhcp.leases'

# Firewall (iptables) plugin is NOT used on OpenWrt 22.03+ (fw4/nftables).
# Per-device traffic comes from nlbwmon (nlbw2collectd) instead.
uci set $LS.collectd_iptables=statistics
uci set $LS.collectd_iptables.enable='0'

# Every enabled plugin needs its collectd-mod-* package, otherwise collectd
# refuses to start ("Could not find plugin ..." / "Parsing the config file failed!").
for SECTION in $(uci show $LS 2>/dev/null | sed -n "s/^$LS\.collectd_\([a-z0-9_]*\)\.enable='1'$/\1/p"); do
    if { [ -f "/usr/share/luci/statistics/plugins/${SECTION}.json" ] || [ "$SECTION" = "logfile" ]; } && \
       [ ! -f "/usr/lib/collectd/${SECTION}.so" ]; then
        uci set $LS.collectd_${SECTION}.enable='0'
        warn "Disabled collectd plugin '${SECTION}' (collectd-mod-${SECTION} is not installed)"
    fi
done

uci commit $LS

# Test the generated collectd configuration before restarting anything
COLLECTD_OK=1
if [ -x /usr/libexec/stat-genconfig ] && command -v collectd >/dev/null 2>&1; then
    TEST_CONF="/tmp/collectd-test.$$.conf"
    if /usr/libexec/stat-genconfig > "$TEST_CONF" 2>/dev/null && collectd -t -C "$TEST_CONF" 2>/tmp/collectd-test.$$.log; then
        ok "collectd configuration test passed"
    else
        COLLECTD_OK=0
        warn "collectd configuration test FAILED:"
        cat /tmp/collectd-test.$$.log 2>/dev/null | sed 's/^/       /'
    fi
    rm -f "$TEST_CONF" /tmp/collectd-test.$$.log
fi

# ------------------------------------------------------------------------------
# Services
# ------------------------------------------------------------------------------

echo ""
echo "Enabling and restarting services..."

restart_service() {
    NAME="$1"
    [ -x "/etc/init.d/$NAME" ] || return 0
    /etc/init.d/"$NAME" enable >/dev/null 2>&1
    /etc/init.d/"$NAME" restart >/dev/null 2>&1
    echo "  restarted $NAME"
}

restart_service cron
restart_service vnstat
restart_service nlbwmon
restart_service netifyd
restart_service prometheus-node-exporter-lua
[ "$DNSMASQ_CHANGED" = "1" ] && restart_service dnsmasq

# luci_statistics regenerates /etc/collectd.conf and (re)starts collectd
if [ -x /etc/init.d/luci_statistics ]; then
    /etc/init.d/collectd enable >/dev/null 2>&1
    /etc/init.d/luci_statistics enable >/dev/null 2>&1
    /etc/init.d/luci_statistics restart >/dev/null 2>&1
    echo "  restarted luci_statistics + collectd"
fi

# LuCI caches menus/pages
rm -rf /tmp/luci-modulecache/ /tmp/luci-indexcache* 2>/dev/null

# ------------------------------------------------------------------------------
# Final validation
# ------------------------------------------------------------------------------

echo ""
echo "Running final validation..."
sleep 5

if [ "$(uci -q get luci_statistics.@collectd_network_server[0].host)" = "$HOMESERVER" ]; then
    ok "collectd sends data to $HOMESERVER:$COLLECTD_PORT"
else
    warn "collectd network server is not set to $HOMESERVER"
fi

if [ "$COLLECTD_OK" = "1" ] && pidof collectd >/dev/null 2>&1; then
    ok "collectd is running"
else
    warn "collectd is NOT running. Check: logread -e collectd"
fi

if [ -f /usr/lib/collectd/lua.so ] && [ -f /usr/share/collectd-mod-lua/nlbw2collectd.lua ]; then
    ok "nlbw2collectd installed (per-device traffic)"
else
    warn "collectd-mod-lua or nlbw2collectd.lua missing (no per-device traffic)"
fi

if [ "$(uci -q get prometheus-node-exporter-lua.main.listen_interface)" = "lan" ]; then
    ok "Prometheus exporter listens on LAN port $(uci -q get prometheus-node-exporter-lua.main.listen_port)"
else
    warn "Prometheus exporter is not set to LAN"
fi

if pidof prometheus-node-exporter-lua >/dev/null 2>&1 || pgrep -f prometheus-node-exporter-lua >/dev/null 2>&1; then
    ok "Prometheus exporter is running"
else
    warn "Prometheus exporter is NOT running. Check: logread -e prometheus"
fi

if command -v netifyd >/dev/null 2>&1; then
    ok "netifyd installed"
else
    warn "netifyd not installed"
fi

if [ -n "$FAILED_PKGS" ]; then
    warn "Packages that failed to install:$FAILED_PKGS"
fi

# ------------------------------------------------------------------------------
# Completion
# ------------------------------------------------------------------------------

echo ""
echo "========================================="
echo " Router Setup Completed ($WARNINGS warning(s))"
echo "========================================="
echo ""
echo "OpenWrt          : $OWRT_RELEASE ($PKG_MANAGER)"
echo "Home Server      : $HOMESERVER"
echo "Router LAN IP    : ${LAN_IP:-unknown}"
echo ""
echo "Backups (*.bak.$BACKUP_DATE):"
echo "  /etc/config/luci_statistics.bak.$BACKUP_DATE"
echo "  /etc/config/prometheus-node-exporter-lua.bak.$BACKUP_DATE"
echo ""
echo "Next steps:"
echo "  - In Docker/prometheus.yml on the Home Server, scrape ${LAN_IP:-<router-ip>}:9100"
echo "  - In Docker/netify-log.sh on the Home Server, set router=${LAN_IP:-<router-ip>}"
echo "  - LuCI -> Statistics -> Graphs shows data after about 1 minute"
echo ""
echo "Useful checks:"
echo "  /etc/init.d/collectd status"
echo "  logread -e collectd"
echo "  ls /tmp/rrd/*/"
echo "  wget -qO- http://${LAN_IP:-<router-ip>}:9100/metrics | head"
echo ""
echo "A router reboot is recommended."
echo ""
exit 0
