#!/usr/bin/env bash

set -Eeuo pipefail

REPO_URL="https://github.com/ryukora/Openwrt-Monitoring.git"
REPO_NAME="Openwrt-Monitoring"

echo "========================================="
echo " OpenWrt Monitoring Server Setup"
echo "========================================="
echo ""

# ------------------------------------------------------------------------------
# Router IP Input
# ------------------------------------------------------------------------------

while true; do
    read -rp "Enter Template Router IP currently in repository files: " TEMPLATE_IP

    if [[ "$TEMPLATE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        break
    fi

    echo "Invalid IPv4 address format."
done

echo ""

while true; do
    read -rp "Enter your OpenWrt Router IP Address: " ROUTER_IP

    if [[ "$ROUTER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        break
    fi

    echo "Invalid IPv4 address format."
done

echo ""
echo "Template IP : $TEMPLATE_IP"
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

if [[ ! "$CONTINUE_SETUP" =~ ^[Yy]$ ]]; then
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

    if [[ "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then
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

    read -rp "Remove and re-clone repository? (Y/n): " RECLONE

    if [[ "$RECLONE" =~ ^[Yy]$ ]]; then
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

if [[ "$CLEAN_REPO" =~ ^[Yy]$ ]]; then
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

ESCAPED_TEMPLATE_IP="${TEMPLATE_IP//./\\.}"

if [[ -f prometheus.yml ]]; then
    sed -i "s/${ESCAPED_TEMPLATE_IP}/${ROUTER_IP}/g" prometheus.yml
fi

if [[ -f netify-log.sh ]]; then
    sed -i "s/${ESCAPED_TEMPLATE_IP}/${ROUTER_IP}/g" netify-log.sh
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

if [[ "$START_DOCKER" =~ ^[Yy]$ ]]; then

    if [[ "$INSTALL_ADGUARD" =~ ^[Yy]$ ]]; then

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
