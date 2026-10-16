#!/bin/sh
# Hysteria 2 Debian V1.4 - 连通修复版
# 用法: bash hy2-v1.4-fixed.sh [-p 端口] [-w 密码] [-i 公网IP]
# NAT鸡必须: bash hy2-v1.4-fixed.sh -i 面板给的公网IP -p 面板映射的端口

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

while getopts "p:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 端口] [-w 密码] [-i 公网IP]"; exit 0 ;;
  esac
done
[ "$(id -u)"!= "0" ] && echo -e "${RED}请用 root 运行${PLAIN}" && exit 1

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends curl wget openssl ca-certificates iproute2 python3 dnsutils cron procps 2>&1 | tail -n 5 || true

HY_PORT=${CUSTOM_PORT:-26169}
HY_PASS=${CUSTOM_PASSWORD:-$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)}
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /var/log; chmod 700 /etc/hysteria

echo -e "${YELLOW}[3/7] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" || wget -q -O /tmp/hysteria "$HY_URL"
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria
/usr/local/bin/hysteria version || true

# 证书
if [! -f /etc/hysteria/cert.crt ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  chmod 600 /etc/hysteria/key.key
fi

cat > /etc/hysteria/config.yaml <<EOF
listen: 0.0.0.0:${HY_PORT}
auth:
  type: password
  password: ${HY_PASS}
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
  alpn: h3
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 45s
  keepAlivePeriod: 15s
bandwidth:
  up: 100 mbps
  down: 500 mbps
ignoreClientBandwidth: true
EOF

# 服务保活 - 核心修复
IS_SYSTEMD=0; [ -d /run/systemd/system ] && [ "$(cat /proc/1/comm)" = "systemd" ] && IS_SYSTEMD=1

cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
if systemctl is-active --quiet hysteria 2>/dev/null; then systemctl restart hysteria
else pkill -9 -f "hysteria.*config.yaml" 2>/dev/null; sleep 1; setsid nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 & sleep 1; ss -unlp | grep hysteria; fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh

if [ "$IS_SYSTEMD" = "1" ]; then
  cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 V1.4 Fixed
After=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable --now hysteria; sleep 2
else
  pkill -9 -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1
  setsid nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
  (crontab -l 2>/dev/null | grep -v "hysteria server"; echo "@reboot sleep 15 && setsid nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1"; echo "*/2 * * * * pgrep -f 'hysteria.*config.yaml' >/dev/null || setsid nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1") | crontab -
fi

# 放行
iptables -C INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || true
nft add rule inet filter input udp dport ${HY_PORT} accept 2>/dev/null || true

ss -unlp | grep $HY_PORT; tail -n 20 /var/log/hysteria.log

# IP
SERVER_IP=${CUSTOM_IP:-$(curl -4fsSL https://api4.ipify.org 2>/dev/null)}
[ -z "$SERVER_IP" ] && SERVER_IP="YOUR_PUBLIC_IP"

# pin - 必须用python3编码
CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')
CERT_PIN_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$CERT_PIN")

echo -e "${GREEN}========== V1.4 完成 ==========${PLAIN}"
echo -e "端口: ${HY_PORT} 密码: ${HY_PASS} IP: ${SERVER_IP}"
echo -e "\n1. 先测这个(必通): hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2-Insecure"
echo -e "\n2. 通了换这个(Karing): hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_PIN_ENC}#Hy2-Pin"
