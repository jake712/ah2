#!/bin/bash

# Ensure the script runs with bash
if [ -z "$BASH_VERSION" ]; then
    echo "Please run this script using bash!"
    exit 1
fi

# Configuration paths
CONFIG_PATH="/etc/hysteria/config.yaml"
MENU_PATH="/usr/local/bin/hy"

# Colors for UI
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Function to restart service and show status
restart_and_check() {
    echo "Restarting Hysteria 2 service..."
    rc-service hysteria restart
    sleep 2
    if rc-service hysteria status | grep -q "started"; then
        echo -e "${GREEN}Hysteria 2 is successfully running!${NC}"
        CURRENT_PORT=$(grep "listen:" $CONFIG_PATH | awk '{print $2}' | sed 's/://')
        CURRENT_PASS=$(grep "password:" $CONFIG_PATH | awk -F'"' '{print $2}')
        echo "----------------------------------------"
        echo -e "Current Port: ${GREEN}$CURRENT_PORT${NC}"
        echo -e "Current Password: ${GREEN}$CURRENT_PASS${NC}"
        echo "----------------------------------------"
    else
        echo -e "${RED}Failed to start Hysteria 2. Please check your logs.${NC}"
    fi
}

# Function to change port
change_port() {
    read -p "Enter new UDP port (1-65535): " new_port
    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -le 65535 ] && [ "$new_port" -ge 1 ]; then
        sed -i "s/listen: .*/listen: :$new_port/" $CONFIG_PATH
        echo -e "${GREEN}Port updated to $new_port successfully.${NC}"
        restart_and_check
    else
        echo -e "${RED}Invalid port number!${NC}"
    fi
}

# Function to change password
change_password() {
    read -p "Enter new password: " new_pass
    if [ -n "$new_pass" ]; then
        sed -i "s/password: .*/password: \"$new_pass\"/" $CONFIG_PATH
        echo -e "${GREEN}Password updated successfully.${NC}"
        restart_and_check
    else
        echo -e "${RED}Password cannot be empty!${NC}"
    fi
}

# The Control Panel Menu (The "hy" command)
create_menu() {
    cat << 'EOF' > $MENU_PATH
#!/bin/bash
CONFIG_PATH="/etc/hysteria/config.yaml"
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

show_menu() {
    clear
    echo "========================================"
    echo "    Hysteria 2 Alpine Control Panel     "
    echo "========================================"
    if rc-service hysteria status | grep -q "started"; then
        echo -e "Status: ${GREEN}Running / Active${NC}"
    else
        echo -e "Status: ${RED}Stopped / Inactive${NC}"
    fi
    
    CURRENT_PORT=$(grep "listen:" $CONFIG_PATH | awk '{print $2}' | sed 's/://')
    CURRENT_PASS=$(grep "password:" $CONFIG_PATH | awk -F'"' '{print $2}')
    echo "Current Port: $CURRENT_PORT"
    echo "Current Password: $CURRENT_PASS"
    echo "========================================"
    echo "1. Change Port"
    echo "2. Change Password"
    echo "3. Restart Hysteria 2"
    echo "4. Stop Hysteria 2"
    echo "5. Start Hysteria 2"
    echo "0. Exit"
    echo "========================================"
    read -p "Enter choices [0-5]: " choice
    
    case $choice in
        1) source /usr/local/bin/install_hy.sh --change-port ;;
        2) source /usr/local/bin/install_hy.sh --change-pass ;;
        3) rc-service hysteria restart && sleep 1 && exec hy ;;
        4) rc-service hysteria stop && sleep 1 && exec hy ;;
        5) rc-service hysteria start && sleep 1 && exec hy ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" && sleep 1 && show_menu ;;
    esac
}
show_menu
EOF
    chmod +x $MENU_PATH
}

# Handle arguments passed internally by the menu
if [ "$1" == "--change-port" ]; then
    change_port
    exit 0
elif [ "$1" == "--change-pass" ]; then
    change_password
    exit 0
fi

# ========================================================
# Main Installation Sequence
# ========================================================
clear
echo "========================================"
echo " Starting Hysteria 2 Installation...     "
echo "========================================"

# Prompt user for inputs
read -p "Please set Hysteria 2 Port (Default 36789): " USER_PORT
USER_PORT=${USER_PORT:-36789}

read -p "Please set Hysteria 2 Password (Default admin123): " USER_PASS
USER_PASS=${USER_PASS:-admin123}

# 1. Install dependencies
echo "Installing dependencies (bash, curl, openssl, tar)..."
apk update
apk add bash curl openssl tar

# 2. Download latest core
echo "Downloading Hysteria 2 execution binary..."
mkdir -p /usr/local/bin
curl -fsSL https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64 -o /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria
/usr/local/bin/hysteria version

# 3. Generate Certificates
echo "Generating self-signed SSL certificates..."
mkdir -p /etc/ssl/private
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout "/etc/ssl/private/bing.key" \
  -out "/etc/ssl/private/bing.crt" \
  -days 3650 -subj "/CN=bing.com"
chmod -R 777 /etc/ssl/private

# 4. Generate Configuration File
echo "Writing configuration variables..."
mkdir -p /etc/hysteria
cat << EOF > $CONFIG_PATH
listen: :$USER_PORT

tls:
  cert: /etc/ssl/private/bing.crt
  key: /etc/ssl/private/bing.key

auth:
  type: password
  password: "$USER_PASS"

ignoreClientBandwidth: true
EOF

# 5. Create OpenRC Service Daemon
echo "Creating daemon manager script..."
cat << 'EOF' > /etc/init.d/hysteria
#!/sbin/openrc-run

name="Hysteria 2 Service"
description="Hysteria 2 Proxy Server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
EOF
chmod +x /etc/init.d/hysteria

# 6. Enable boot persistent execution and execute
rc-update add hysteria default

# Keep a persistent copy of the installer engine for menu flags reference
cp "$0" /usr/local/bin/install_hy.sh 2>/dev/null || true
chmod +x /usr/local/bin/install_hy.sh

# 7. Create panel console entry shortcut
create_menu

# Final Status Fire-up
restart_and_check
echo -e "${GREEN}Installation finalized.${NC} You can now type ${GREEN}hy${NC} at any time to open the management console panel!"
