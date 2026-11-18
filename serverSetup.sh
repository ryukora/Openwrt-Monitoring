#!/usr/bin/env bash

set -Eeuo pipefail

REPO_URL="https://github.com/ryukora/Openwrt-Monitoring.git"
REPO_NAME="Openwrt-Monitoring"

# Enter (empty answer) = default "yes" for (Y/n) prompts
is_yes() {
    [[ -z "$1" || "$1" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

is_ipv4() {
    local IFS=.
    local -a octets
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r -a octets <<< "$1"
    for o in "${octets[@]}"; do
        (( 10#$o <= 255 )) || return 1
    done
}

echo "========================================="
echo " OpenWrt Monitoring Server Setup"
echo "========================================="
echo ""

# ------------------------------------------------------------------------------
# Router IP Input
# ------------------------------------------------------------------------------

while true; do
    read -rp "Enter your OpenWrt Router IP Address (LAN IP, e.g. 192.168.1.1): " ROUTER_IP

    if is_ipv4 "$ROUTER_IP"; then
        break
    fi

    echo "Invalid IPv4 address."
done

echo ""
echo "Router IP   : $ROUTER_IP"
echo ""

# ------------------------------------------------------------------------------
# Installation Location
# ------------------------------------------------------------------------------

echo "Installation Location:"
echo "1) Current Directory ($(pwd))"
echo "2) /root"
echo "3) /opt"
echo "4) Custom Path"
echo ""

read -rp "Select [1-4]: " INSTALL_CHOICE

case "$INSTALL_CHOICE" in
    1)
        INSTALL_DIR="$(pwd)"
        ;;
    2)
        INSTALL_DIR="/root"
        ;;
    3)
        INSTALL_DIR="/opt"
        ;;
    4)
        read -rp "Enter custom path: " INSTALL_DIR
        ;;
    *)
        echo "Invalid selection."
        exit 1
        ;;
esac

mkdir -p "$INSTALL_DIR"

echo ""
echo "Repository will be installed to:"
echo "$INSTALL_DIR/$REPO_NAME"
echo ""

read -rp "Continue? (Y/n): " CONTINUE_SETUP

if ! is_yes "$CONTINUE_SETUP"; then
    echo "Setup cancelled."
    exit 0
fi

# ------------------------------------------------------------------------------
# Required Packages
# ------------------------------------------------------------------------------

for cmd in git curl sed; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "$cmd not found."
        echo "Installing..."
        sudo apt update
        sudo apt install -y "$cmd"
    fi
done

# ------------------------------------------------------------------------------
# Docker Installation
# ------------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
    echo ""
    echo "Docker is not installed."

    read -rp "Install Docker now? (Y/n): " INSTALL_DOCKER

    if is_yes "$INSTALL_DOCKER"; then
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        rm -f get-docker.sh

        echo "Waiting for Docker service..."
        sleep 5
    else
        echo "Docker installation aborted."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Docker Compose Plugin
# ------------------------------------------------------------------------------

if ! docker compose version >/dev/null 2>&1; then
    echo ""
    echo "Docker Compose Plugin not found."

    sudo apt update
    sudo apt install -y docker-compose-plugin

    if ! docker compose version >/dev/null 2>&1; then
        echo "Failed to install Docker Compose Plugin."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Docker Network
# ------------------------------------------------------------------------------

if ! docker network inspect internal >/dev/null 2>&1; then
    echo "Creating Docker network: internal"
    sudo docker network create internal
else
    echo "Docker network 'internal' already exists."
fi

# ------------------------------------------------------------------------------
# Clone Repository
# ------------------------------------------------------------------------------

TARGET_DIR="$INSTALL_DIR/$REPO_NAME"

if [[ -d "$TARGET_DIR" ]]; then
    echo ""
    echo "Existing repository found:"
    echo "$TARGET_DIR"

    # Default is NO here: re-cloning deletes local changes in that folder
    read -rp "Remove and re-clone repository? (y/N): " RECLONE

    if [[ "$RECLONE" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
        rm -rf "$TARGET_DIR"
    else
        echo "Setup aborted."
        exit 1
    fi
fi

echo ""
echo "Cloning repository..."

git clone "$REPO_URL" "$TARGET_DIR"

# ------------------------------------------------------------------------------
# Optional Cleanup
# ------------------------------------------------------------------------------

echo ""
read -rp "Remove unused folders/files (Python, Router, screenshots, docs)? (Y/n): " CLEAN_REPO

if is_yes "$CLEAN_REPO"; then
    rm -rf "$TARGET_DIR/Python" 2>/dev/null || true
    rm -rf "$TARGET_DIR/Router" 2>/dev/null || true
    rm -rf "$TARGET_DIR/screenshots" 2>/dev/null || true

    rm -f "$TARGET_DIR/serverSetup.sh" 2>/dev/null || true
    rm -f "$TARGET_DIR/routersetup.sh" 2>/dev/null || true
    rm -f "$TARGET_DIR/README.md" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# Docker Directory
# ------------------------------------------------------------------------------

DOCKER_DIR="$TARGET_DIR/Docker"

cd "$DOCKER_DIR" || {
    echo "Failed to enter Docker directory."
    exit 1
}

# ------------------------------------------------------------------------------
# Router IP Replacement
# ------------------------------------------------------------------------------

echo ""
echo "Updating configuration files..."

# The repository files contain example router IPs (prometheus.yml: 10.0.5.1,
# netify-log.sh: 10.1.1.1). Replace them by position, not by a "template IP".

if [[ -f prometheus.yml ]]; then
    # job 'openwrt-prom': targets: ['<router-ip>:9100']
    sed -i -E "s/(targets: \[')[0-9.]+(:9100'\])/\1${ROUTER_IP}\2/" prometheus.yml
fi

if [[ -f netify-log.sh ]]; then
    sed -i -E "s/^router=[0-9.]+/router=${ROUTER_IP}/" netify-log.sh
fi

chmod +x netify-log.sh

# ------------------------------------------------------------------------------
# Cronjob
# ------------------------------------------------------------------------------

echo ""
echo "Creating cronjob..."

sudo rm -f /etc/cron.d/netify-log-cronjob

sudo bash -c "cat > /etc/cron.d/netify-log-cronjob <<EOF
*/1 * * * * root $DOCKER_DIR/netify-log.sh >> /var/log/crontab.netify.txt 2>&1
EOF"

sudo chmod 644 /etc/cron.d/netify-log-cronjob

# ------------------------------------------------------------------------------
# AdGuard Option
# ------------------------------------------------------------------------------

INSTALL_ADGUARD="n"

read -rp "Install AdGuard Home stack? (Y/n): " INSTALL_ADGUARD

# ------------------------------------------------------------------------------
# Start Containers
# ------------------------------------------------------------------------------

echo ""
read -rp "Start Docker containers now? (Y/n): " START_DOCKER

if is_yes "$START_DOCKER"; then

    if is_yes "$INSTALL_ADGUARD"; then

        if [[ -f docker-compose-extras.yml ]]; then
            sudo docker compose -f docker-compose-extras.yml up -d
        else
            echo "docker-compose-extras.yml not found."
            exit 1
        fi

    else
        sudo docker compose up -d
    fi

    echo ""
    sudo docker compose ps || true

else
    echo "Docker containers were not started."
fi

echo ""
echo "========================================="
echo " Setup Completed"
echo "========================================="
echo ""
echo "Repository Location:"
echo "$TARGET_DIR"
echo ""
echo "Router IP:"
echo "$ROUTER_IP"
echo ""
echo "Cron Job:"
echo "/etc/cron.d/netify-log-cronjob"
echo ""
