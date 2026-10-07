#!/bin/bash
set -e
if [ "$EUID" -ne 0 ]; then echo "請用 sudo / root 執行"; exit 1; fi
PORT=${1:-26836}
# 從 -p -i 解析，兼容你原來的用法
while getopts "p:w:i:h" opt; do case $opt in p) PORT=$OPTARG;; w) PASS=$OPTARG;; i) IP=$OPTARG;; esac; done

apt-get update -qq && apt-get install -y -qq curl wget openssl iproute2 2>/dev/null || true

ARCH=$(uname -m); [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && HA="arm64" || HA="amd64"
URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HA}"
curl -fL --max-time 30 -o /usr/local/bin/hysteria "$URL" || wget -q -O /usr/local/bin/hysteria "$URL"
chmod +x /usr/local/bin/hysteria

[ -z "$PASS" ] && PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
[ -z "$IP" ] && IP=$(curl -4fsSL --max-time 4 https://api4.ipify.org || echo "YOUR_IP")

mkdir -p /etc/hysteria
[! -f /etc/hysteria/cert.crt ] && {
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
}

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

# systemd 比 nohup 穩定 100 倍
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
sleep 2
systemctl status hysteria --no-pager
ss -unlp | grep -- "$PORT"
cat /var/log/syslog 2>/dev/null | grep hysteria | tail -n 20 || journalctl -u hysteria -n 20 --no-pager

# 防火牆自動放行
ufw allow ${PORT}/udp 2>/dev/null || true
iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || true

if [[ "$IP" == *:* ]]; then IP_URL="[$IP]"; else IP_URL="$IP"; fi
echo "========== 完成 =========="
echo "hysteria2://${PASS}@${IP_URL}:${PORT}/?sni=bing.com&insecure=1#Debian-${PORT}"
