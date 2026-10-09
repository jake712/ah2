#!/bin/bash
set -e
if [ "$EUID" -ne 0 ]; then echo "Please run as root"; exit 1; fi

PORT=5174
PASS=""
IP="202.160.76.247"

while getopts "p:w:i:h" opt; do
 case $opt in
  p) PORT=$OPTARG ;;
  w) PASS=$OPTARG ;;
  i) IP=$OPTARG ;;
  h) echo "Usage: $0 [-p port] [-w password] [-i IP/domain]"; exit 0 ;;
 esac
done

# Install deps
apt-get update -qq && apt-get install -y -qq curl wget openssl iproute2 2>/dev/null || apk add --no-cache curl wget openssl iproute2 2>/dev/null || true

ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then HA="arm64"; else HA="amd64"; fi
URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HA}"
echo "Downloading $URL ..."
curl -fL --max-time 30 -o /usr/local/bin/hysteria "$URL" || wget -q -O /usr/local/bin/hysteria "$URL"
chmod +x /usr/local/bin/hysteria

if [ -z "$PASS" ]; then
  PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  [ -z "$PASS" ] && PASS="Hy2$(date +%s | tail -c 6)"
fi

if [ -z "$IP" ]; then
  IP=$(curl -4fsSL --max-time 4 https://api4.ipify.org 2>/dev/null || echo "YOUR_IP")
fi

mkdir -p /etc/hysteria

# FIX 1: added spaces inside [ ]
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  echo "Generating self-signed cert..."
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  chmod 600 /etc/hysteria/key.key 2>/dev/null || true
fi

# FIX 2: rewrite config.yaml correctly
cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key

auth:
  type: password
  password: ${PASS}

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
    # optional: insecure if needed
    # insecure: true
EOF

# FIX 2b: rewrite systemd service
cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || true

systemctl daemon-reload
systemctl enable hysteria >/dev/null 2>&1 || true
systemctl restart hysteria

sleep 2
systemctl status hysteria --no-pager || true

# FIX 3: fixed IP bracket check - added spaces
if [[ "$IP" == *:* ]] && [[ "$IP" != \[*\] ]]; then
  IP_URL="[$IP]"
else
  IP_URL="$IP"
fi

echo ""
echo "========== 完成 =========="
echo "端口: $PORT"
echo "密碼: $PASS"
echo "IP: $IP"
echo ""
echo "hysteria2://${PASS}@${IP_URL}:${PORT}/?sni=bing.com&insecure=1#Debian-${PORT}"
echo ""
/usr/local/bin/hysteria version || true
