#!/bin/sh

set -e

REPO_BASE="https://raw.githubusercontent.com/ryukora/Openwrt-Monitoring/refs/heads/main"

echo "========================================="
echo " OpenWrt Monitoring Router Setup"
echo "========================================="
echo ""

# ------------------------------------------------------------------------------
# Home Server Configuration
# ------------------------------------------------------------------------------

while true; do
    printf "Enter Template Home Server IP currently used in configs: "
    read TEMPLATE_HOMESERVER

    case "$TEMPLATE_HOMESERVER" in
        *.*.*.*) break ;;
        *) echo "Invalid IPv4 address." ;;
    esac
done

echo ""

while true; do
    printf "Enter Home Server IP Address: "
    read HOMESERVER

    case "$HOMESERVER" in
        *.*.*.*) break ;;
        *) echo "Invalid IPv4 address." ;;
    esac
done

echo ""
echo "Template Home Server : $TEMPLATE_HOMESERVER"
echo "Actual Home Server   : $HOMESERVER"
echo ""

printf "Continue? (Y/n): "
read CONTINUE_SETUP

case "$CONTINUE_SETUP" in
    Y|y) ;;
    *) echo "Setup cancelled."; exit 0 ;;
esac

# ------------------------------------------------------------------------------
# Internet & DNS Check
# ------------------------------------------------------------------------------

echo "Checking internet connectivity..."

if ! ping -c1 1.1.1.1 >/dev/null 2>&1; then
    echo "ERROR: Internet connectivity failed."
    echo "Check WAN, gateway, firewall, or routing."
    exit 1
fi

echo "Internet connectivity OK."

echo "Checking DNS resolution..."

if ! nslookup github.com >/dev/null 2>&1; then
    echo "ERROR: DNS resolution failed."
    echo "Check DNS configuration."
    exit 1
fi

echo "DNS resolution OK."

# ------------------------------------------------------------------------------
# Package Manager Detection
# ------------------------------------------------------------------------------

if command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER="opkg"
elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
else
    echo "ERROR: No supported package manager found."
    exit 1
fi

echo "Using package manager: $PKG_MANAGER"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

download_file() {
    URL="$1"
    DEST="$2"

    echo "Downloading: $DEST"

    wget -q "$URL" -O "$DEST" || {
        echo "Failed downloading:"
        echo "$URL"
        exit 1
    }

    if [ ! -s "$DEST" ]; then
        echo "Downloaded file is empty:"
        echo "$DEST"
        exit 1
    fi
}

add_cron() {
    ENTRY="$1"

    crontab -l 2>/dev/null | grep -Fq "$ENTRY" && return

    (
        crontab -l 2>/dev/null
        echo "$ENTRY"
    ) | crontab -
}

package_exists() {
    PKG="$1"

    if [ "$PKG_MANAGER" = "opkg" ]; then
        opkg list | grep -q "^${PKG} "
    else
        apk search "$PKG" | grep -q "^${PKG}$"
    fi
}

# ------------------------------------------------------------------------------
# Alias
# ------------------------------------------------------------------------------

mkdir -p /etc/profile.d

cat << "EOF" > /etc/profile.d/alias.sh
alias cls="clear"
EOF

# ------------------------------------------------------------------------------
# Package Lists Update
# ------------------------------------------------------------------------------

echo "Updating package lists..."

if [ "$PKG_MANAGER" = "opkg" ]; then
    opkg update
else
    apk update
fi

# ------------------------------------------------------------------------------
# Packages
# ------------------------------------------------------------------------------

SOFTWARE="
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
collectd-mod-iptables
collectd-mod-ping
luci-app-statistics
collectd-mod-dhcpleases
prometheus-node-exporter-lua
prometheus-node-exporter-lua-nat_traffic
prometheus-node-exporter-lua-netstat
prometheus-node-exporter-lua-openwrt
prometheus-node-exporter-lua-uci_dhcp_host
"

echo "Checking packages..."
for PKG in $SOFTWARE
do

    if package_exists "$PKG"; then
        echo "$PKG available."
    else
        echo "WARNING: $PKG not found in repository."
        continue
    fi

    if [ "$PKG_MANAGER" = "opkg" ]; then

        if opkg list-installed | grep -q "^${PKG} "; then
            echo "$PKG already installed"
            continue
        fi

        opkg install "$PKG" || echo "Failed installing $PKG"

    else

        if apk info "$PKG" >/dev/null 2>&1; then
            echo "$PKG already installed"
            continue
        fi

        apk add "$PKG" || echo "Failed installing $PKG"

    fi

done

# ------------------------------------------------------------------------------
# Required Directories
# ------------------------------------------------------------------------------

mkdir -p /etc/collectd/conf.d
mkdir -p /usr/share/collectd-mod-lua
mkdir -p /usr/lib/lua/prometheus-collectors
mkdir -p /etc/hotplug.d/dhcp

# ------------------------------------------------------------------------------
# nlbw2collectd
# ------------------------------------------------------------------------------

echo "Installing nlbw2collectd..."

download_file \
"${REPO_BASE}/Router/nlbw2collectd/lua.conf" \
"/etc/collectd/conf.d/lua.conf"

download_file \
"${REPO_BASE}/Router/nlbw2collectd/nlbw2collectd.lua" \
"/usr/share/collectd-mod-lua/nlbw2collectd.lua"

# ------------------------------------------------------------------------------
# nlbwmon Refresh Interval
# ------------------------------------------------------------------------------

if [ -f /etc/config/nlbwmon ]; then
    sed -i 's/option refresh_interval 30s/option refresh_interval 10s/g' \
        /etc/config/nlbwmon
fi

# ------------------------------------------------------------------------------
# vnStat Configuration
# ------------------------------------------------------------------------------

VNSTAT_MOUNT="/tmp/mountd/disk1_part1"

if [ -d "$VNSTAT_MOUNT" ]; then

    BACKUP_DATE="$(date +%Y%m%d-%H%M%S)"

    cp /etc/vnstat.conf "/etc/vnstat.conf.${BACKUP_DATE}"

    sed -i 's/;DatabaseDir /DatabaseDir /g' /etc/vnstat.conf
    sed -i 's,/var/lib/vnstat,/tmp/mountd/disk1_part1/vnstat,g' \
        /etc/vnstat.conf

fi

# ------------------------------------------------------------------------------
# WrtBWMon
# ------------------------------------------------------------------------------

echo "Installing WrtBWMon..."

download_file \
"https://github.com/brvphoenix/wrtbwmon/releases/download/v1.2.1-3/wrtbwmon_1.2.1-3_all.ipk" \
"/tmp/wrtbwmon.ipk"

download_file \
"https://github.com/brvphoenix/luci-app-wrtbwmon/releases/download/release-2.0.13/luci-app-wrtbwmon_2.0.13_all.ipk" \
"/tmp/luci-app-wrtbwmon.ipk"

if [ "$PKG_MANAGER" = "opkg" ]; then
    opkg install /tmp/wrtbwmon.ipk || true
    opkg install /tmp/luci-app-wrtbwmon.ipk || true
fi

rm -f /tmp/wrtbwmon.ipk
rm -f /tmp/luci-app-wrtbwmon.ipk

# ------------------------------------------------------------------------------
# Scripts
# ------------------------------------------------------------------------------

echo "Installing scripts..."

download_file "${REPO_BASE}/Router/scripts/speedtest.sh" "/usr/bin/speedtest.sh"
download_file "${REPO_BASE}/Router/scripts/15-second-script.sh" "/usr/bin/15-second-script.sh"
download_file "${REPO_BASE}/Router/scripts/1-minute-script.sh" "/usr/bin/1-minute-script.sh"
download_file "${REPO_BASE}/Router/scripts/1-hour-script.sh" "/usr/bin/1-hour-script.sh"
download_file "${REPO_BASE}/Router/scripts/5-minute-script.sh" "/usr/bin/5-minute-script.sh"
download_file "${REPO_BASE}/Router/scripts/12am-script.sh" "/usr/bin/12am-script.sh"
download_file "${REPO_BASE}/Router/scripts/device-status-ping.sh" "/usr/bin/device-status-ping.sh"
download_file "${REPO_BASE}/Router/scripts/packet-loss.sh" "/usr/bin/packet-loss.sh"
download_file "${REPO_BASE}/Router/scripts/new_device.sh" "/usr/bin/new_device.sh"
download_file "${REPO_BASE}/Router/scripts/internet-outage.sh" "/usr/bin/internet-outage.sh"

chmod +x /usr/bin/speedtest.sh
chmod +x /usr/bin/15-second-script.sh
chmod +x /usr/bin/1-minute-script.sh
chmod +x /usr/bin/1-hour-script.sh
chmod +x /usr/bin/5-minute-script.sh
chmod +x /usr/bin/12am-script.sh
chmod +x /usr/bin/device-status-ping.sh
chmod +x /usr/bin/packet-loss.sh
chmod +x /usr/bin/new_device.sh
chmod +x /usr/bin/internet-outage.sh

download_file \
"${REPO_BASE}/Router/scripts/99-new-device" \
"/etc/hotplug.d/dhcp/99-new-device"

chmod +x /etc/hotplug.d/dhcp/99-new-device

# ------------------------------------------------------------------------------
# Lua Collectors
# ------------------------------------------------------------------------------

echo "Installing Lua collectors..."

download_file \
"${REPO_BASE}/Router/lua/nat_traffic.lua" \
"/usr/lib/lua/prometheus-collectors/nat_traffic.lua"

download_file \
"${REPO_BASE}/Router/lua/speedtest.lua" \
"/usr/lib/lua/prometheus-collectors/speedtest.lua"

download_file \
"${REPO_BASE}/Router/lua/wanip.lua" \
"/usr/lib/lua/prometheus-collectors/wanip.lua"

download_file \
"${REPO_BASE}/Router/lua/packetloss.lua" \
"/usr/lib/lua/prometheus-collectors/packetloss.lua"

download_file \
"${REPO_BASE}/Router/lua/new_device.lua" \
"/usr/lib/lua/prometheus-collectors/new_device.lua"

download_file \
"${REPO_BASE}/Router/lua/vnstatmonth.lua" \
"/usr/lib/lua/prometheus-collectors/vnstatmonth.lua"

download_file \
"${REPO_BASE}/Router/lua/gl-router-temp.lua" \
"/usr/lib/lua/prometheus-collectors/gl-router-temp.lua"

download_file \
"${REPO_BASE}/Router/lua/internet-outage.lua" \
"/usr/lib/lua/prometheus-collectors/internet-outage.lua"

download_file \
"${REPO_BASE}/Router/lua/dnsmasq.lua" \
"/usr/lib/lua/prometheus-collectors/dnsmasq.lua"

download_file \
"${REPO_BASE}/Router/lua/uci_dhcp_host.lua" \
"/usr/lib/lua/prometheus-collectors/uci_dhcp_host.lua"

download_file \
"${REPO_BASE}/Router/collectd-lua/collectd.conf" \
"/etc/collectd/conf.d/collectd.conf"

download_file \
"${REPO_BASE}/Router/collectd-lua/device-status.lua" \
"/usr/lib/lua/prometheus-collectors/device-status.lua"

download_file \
"${REPO_BASE}/Router/wrtbwmon" \
"/usr/sbin/wrtbwmon"

chmod +x /usr/sbin/wrtbwmon

# ------------------------------------------------------------------------------
# DHCP Script Configuration
# ------------------------------------------------------------------------------

if uci get dhcp.@dnsmasq[0] >/dev/null 2>&1; then

    echo "Configuring dnsmasq DHCP script..."

    uci set dhcp.@dnsmasq[0].dhcpscript='/usr/bin/new_device.sh'
    uci commit dhcp

fi

# ------------------------------------------------------------------------------
# Cron Jobs
# ------------------------------------------------------------------------------

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

# Optional compatibility marker from original script
# add_cron "59 * * 12 * /ready"

# ------------------------------------------------------------------------------
# Prometheus Node Exporter
# ------------------------------------------------------------------------------

if [ -f /etc/config/prometheus-node-exporter-lua ]; then

    cp \
        /etc/config/prometheus-node-exporter-lua \
        "/etc/config/prometheus-node-exporter-lua.bak.$(date +%Y%m%d-%H%M%S)"

    sed -i 's/loopback/lan/g' \
        /etc/config/prometheus-node-exporter-lua

fi

# ------------------------------------------------------------------------------
# LuCI Statistics Configuration
# ------------------------------------------------------------------------------

if [ -f /etc/config/luci_statistics ]; then

    BACKUP_DATE="$(date +%Y%m%d-%H%M%S)"

    cp \
        /etc/config/luci_statistics \
        "/etc/config/luci_statistics.bak.${BACKUP_DATE}"

    ESCAPED_TEMPLATE_HOMESERVER="$(printf '%s\n' "$TEMPLATE_HOMESERVER" | sed 's/\./\\./g')"

    sed -i \
        "s/${ESCAPED_TEMPLATE_HOMESERVER}/${HOMESERVER}/g" \
        /etc/config/luci_statistics

    if ! grep -q "5minute" /etc/config/luci_statistics; then

        sed -i \
        "/option RRATimespans/s/'\(.*\)'/'5minute 15minute 30minute 1hour \1'/" \
        /etc/config/luci_statistics

    fi

fi

# ------------------------------------------------------------------------------
# Services
# ------------------------------------------------------------------------------

echo "Enabling and restarting services..."

if [ -x /etc/init.d/cron ]; then
    /etc/init.d/cron enable
    /etc/init.d/cron restart
fi

if [ -x /etc/init.d/wrtbwmon ]; then
    /etc/init.d/wrtbwmon enable
    /etc/init.d/wrtbwmon restart
fi

if [ -x /etc/init.d/vnstat ]; then
    /etc/init.d/vnstat restart
fi

if [ -x /etc/init.d/luci_statistics ]; then
    /etc/init.d/luci_statistics enable
fi

if [ -x /etc/init.d/collectd ]; then
    /etc/init.d/collectd enable
    /etc/init.d/collectd restart
fi

if [ -x /etc/init.d/prometheus-node-exporter-lua ]; then
    /etc/init.d/prometheus-node-exporter-lua restart
fi

if [ -x /etc/init.d/dnsmasq ]; then
    /etc/init.d/dnsmasq restart
fi

if [ -x /etc/init.d/firewall ]; then
    /etc/init.d/firewall restart
fi

# ------------------------------------------------------------------------------
# Final Validation
# ------------------------------------------------------------------------------

echo ""
echo "Running final validation..."

if [ -f /etc/config/luci_statistics ]; then
    if grep -q "$HOMESERVER" /etc/config/luci_statistics; then
        echo "[OK] Home Server IP updated in luci_statistics"
    else
        echo "[WARN] Home Server IP not found in luci_statistics"
    fi
fi

if [ -f /etc/config/prometheus-node-exporter-lua ]; then
    if grep -q "lan" /etc/config/prometheus-node-exporter-lua; then
        echo "[OK] Prometheus exporter configured for LAN"
    else
        echo "[WARN] Prometheus exporter configuration may require review"
    fi
fi

if command -v collectd >/dev/null 2>&1; then
    echo "[OK] collectd installed"
else
    echo "[WARN] collectd not detected"
fi

if command -v netifyd >/dev/null 2>&1; then
    echo "[OK] netifyd installed"
else
    echo "[WARN] netifyd not detected"
fi

# ------------------------------------------------------------------------------
# Completion
# ------------------------------------------------------------------------------

echo ""
echo "========================================="
echo " Router Setup Completed"
echo "========================================="
echo ""
echo "Template Home Server : $TEMPLATE_HOMESERVER"
echo "Actual Home Server   : $HOMESERVER"
echo ""
echo "Backups created:"
echo "  /etc/config/luci_statistics.bak.*"
echo "  /etc/config/prometheus-node-exporter-lua.bak.*"
echo ""
echo "Recommended checks:"
echo "  service collectd status"
echo "  service prometheus-node-exporter-lua status"
echo "  logread -e collectd"
echo "  logread -e prometheus"
echo ""
echo "A router reboot is recommended."
echo ""
exit 0
