#!/bin/bash
set -e
if [ "$EUID" -ne 0 ]; then echo "請用 sudo / root 執行"; exit 1; fi

PORT=26836
PASS=""
IP=""

while getopts "p:w:i:h" opt; do
  case $opt in
    p) PORT=$OPTARG ;;
    w) PASS=$OPTARG ;;
    i) IP=$OPTARG ;;
    h) echo "用法: $0 [-p 端口] [-w 密码] [-i IP/域名]"; exit 0 ;;
  esac
done

apt-get update -qq && apt-get install -y -qq curl wget openssl iproute2 2>/dev/null || true

ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then HA="arm64"; else HA="amd64"; fi
URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HA}"
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
if [! -f /etc/hysteria/cert.crt ] || [! -f /etc/hysteria/key.key ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  chmod 600 /etc/hysteria/key.key 2>/dev/null || true
fi

cat > /etc/hysteria/config.yaml <<EOF
listen: 0.0.0.0:${PORT}
auth:
  type: password
  password: ${PASS}
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
ignoreClientBandwidth: true
EOF

cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target
[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hysteria
sleep 1
systemctl status hysteria --no-pager -l || true
ss -unlp | grep -- "$PORT" || ss -tulpn | grep -- "$PORT" || journalctl -u hysteria -n 20 --no-pager

ufw allow ${PORT}/udp 2>/dev/null || true
iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || true

if [[ "$IP" == *:* ]] && [[ "$IP"!= "["*"]" ]]; then
  IP_URL="[$IP]"
else
  IP_URL="$IP"
fi

echo "========== 完成 =========="
echo "端口: $PORT"
echo "密碼: $PASS"
echo "hysteria2://${PASS}@${IP_URL}:${PORT}/?sni=bing.com&insecure=1#Debian-${PORT}"
