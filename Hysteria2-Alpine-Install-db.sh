cat > /tmp/hy2-fix.sh <<'EOS'
#!/bin/bash
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

if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}请用 root 运行${PLAIN}"
  exit 1
fi

echo -e "${GREEN}=== Hysteria2 Universal V1.2 Fix ===${PLAIN}"

if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo "检测到 Podman，保留 DNS"
else
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

if command -v apk >/dev/null 2>&1; then
  apk add --no-cache curl wget openssl ca-certificates bind-tools iproute2 >/dev/null 2>&1 || true
elif command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends curl wget openssl ca-certificates dnsutils iproute2 >/dev/null 2>&1 || true
fi

HY_PORT=${CUSTOM_PORT:-27237}
if [ -n "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$CUSTOM_PASSWORD
else
  HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
fi
if [ -z "$HY_PASS" ]; then
  HY_PASS="Hy2$(date +%s | tail -c 6)"
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  *) HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /var/log
chmod 700 /etc/hysteria 2>/dev/null || true

echo -e "${YELLOW}[3/6] 下载 Hysteria2 ${HY_ARCH}...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
if command -v curl >/dev/null 2>&1; then
  curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" || true
fi
if [ ! -s /tmp/hysteria ] && command -v wget >/dev/null 2>&1; then
  wget -q --timeout=30 -O /tmp/hysteria "$HY_URL" || true
fi
if [ ! -s /tmp/hysteria ]; then
  echo -e "${RED}下载失败${PLAIN}"; exit 1
fi
mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

echo -e "${YELLOW}[4/6] 生成证书...${PLAIN}"
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  chmod 600 /etc/hysteria/key.key
fi

cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}
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
EOF

echo -e "${YELLOW}[5/6] 启动服务...${PLAIN}"
if command -v rc-service >/dev/null 2>&1; then
  cat > /etc/init.d/hysteria <<'INIT'
#!/sbin/openrc-run
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria.pid"
INIT
  chmod +x /etc/init.d/hysteria
  rc-update add hysteria default 2>/dev/null || true
  rc-service hysteria restart 2>/dev/null || rc-service hysteria start 2>/dev/null || { nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 & }
else
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
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable hysteria 2>/dev/null || true
  systemctl restart hysteria 2>/dev/null || { pkill -f "hysteria.*config" 2>/dev/null; nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 & }
fi
sleep 2

is_private_ip() {
  case "$1" in
    0.0.0.0|10.*|192.168.*|127.*|169.254.*) return 0 ;;
    172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;;
  esac
  echo "$1" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.' && return 0
  return 1
}

get_pub_ip() {
  local ip
  for api in https://api4.ipify.org https://icanhazip.com; do
    ip=$(curl -4fsSL --max-time 4 "$api" 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
    if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi
  done
}

if [ -n "$CUSTOM_IP" ]; then
  SERVER_IP=$CUSTOM_IP
else
  SERVER_IP=$(get_pub_ip)
fi
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="YOUR_PUBLIC_IP"
fi

CERT_SHA256=$(openssl x509 -in /etc/hysteria/cert.crt -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-Z' 'a-z')
CERT_COLON=$(openssl x509 -in /etc/hysteria/cert.crt -noout -fingerprint -sha256 | cut -d= -f2)

cat > /etc/hysteria/clash.yaml <<EOF
proxies:
    - name: Hy2-${SERVER_IP}
    type: hysteria2
    server: ${SERVER_IP}
    port: ${HY_PORT}
    password: ${HY_PASS}
    sni: bing.com
    skip-cert-verify: true
EOF

cat > /etc/hysteria/karing.json <<EOF
{
  "outbounds": [{
    "type": "hysteria2",
    "tag": "Hy2-Karing",
    "server": "${SERVER_IP}",
    "server_port": ${HY_PORT},
    "password": "${HY_PASS}",
    "tls": { "enabled": true, "server_name": "bing.com", "insecure": true, "alpn": ["h3"] }
  }]
}
EOF

LINK1="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2-${SERVER_IP}"
LINK2="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_SHA256}#Hy2-Karing"

echo ""
echo -e "${GREEN}========== 完成 ${SERVER_IP}:${HY_PORT} ==========${PLAIN}"
echo -e "端口: ${CYAN}${HY_PORT}${PLAIN} 密码: ${CYAN}${HY_PASS}${PLAIN}"
echo -e "指纹: ${CYAN}${CERT_COLON}${PLAIN}"
echo ""
echo -e "${GREEN}v2rayN 通用 (需勾选 允许不安全):${PLAIN}"
echo -e "${YELLOW}${LINK1}${PLAIN}"
echo ""
echo -e "${GREEN}Karing 推荐 (pinSHA256):${PLAIN}"
echo -e "${YELLOW}${LINK2}${PLAIN}"
echo ""
echo -e "Clash: cat /etc/hysteria/clash.yaml"
echo -e "证书: cat /etc/hysteria/cert.crt"
EOS
chmod +x /tmp/hy2-fix.sh
bash /tmp/hy2-fix.sh -p 27237 -i 138.2.74.42
