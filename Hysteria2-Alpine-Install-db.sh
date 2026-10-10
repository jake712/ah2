#!/bin/bash
# Hysteria 2 Debian V1.1 - v2n/Karing 证书修复版
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

if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

# ===== [1/6] 基础依赖 =====
echo -e "${YELLOW}[1/6] 检查依赖...${PLAIN}"
export DEBIAN_FRONTEND=noninteractive
if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "检测到 Podman，保留原 DNS"
else
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

if ! command -v apt-get >/dev/null 2>&1; then echo -e "${RED}不是 Debian/Ubuntu${PLAIN}"; exit 1; fi
APT_UPDATED=0
apt_update() { if [ $APT_UPDATED -eq 0 ]; then apt-get update -qq; APT_UPDATED=1; fi; }
ensure_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    apt_update
    apt-get install -y --no-install-recommends "$2" 2>&1 || apt-get install -y "$2" 2>&1 || true
  fi
}
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then apt_update; apt-get install -y --no-install-recommends curl || true; fi
ensure_cmd openssl openssl
ensure_cmd dig dnsutils
if ! command -v ss >/dev/null 2>&1; then apt_update; apt-get install -y --no-install-recommends iproute2 || true; fi

# ===== [2/6] 参数 =====
HY_PORT=${CUSTOM_PORT:-26169}
if [ -n "$CUSTOM_PASSWORD" ]; then HY_PASS=$CUSTOM_PASSWORD
else
  if command -v openssl >/dev/null 2>&1; then HY_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
  else HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16); fi
fi
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /var/log; chmod 700 /etc/hysteria

# ===== [3/6] 下载 =====
echo -e "${YELLOW}[3/6] 下载 Hysteria2...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria; ok=0
for i in 1 2 3; do
  if command -v curl >/dev/null 2>&1; then curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" && ok=1 && break; fi
  if command -v wget >/dev/null 2>&1; then wget -q --timeout=30 -O /tmp/hysteria "$HY_URL" && ok=1 && break; fi
done
[ "$ok" != "1" ] && { echo "下载失败"; exit 1; }
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria

# ===== [4/6] 证书和配置 =====
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
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

# ===== [5/6] 服务 =====
cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
pkill -f "hysteria.*config.yaml" || true; sleep 1
if systemctl is-active --quiet hysteria 2>/dev/null; then systemctl restart hysteria
else nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 & fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable hysteria >/dev/null 2>&1; systemctl restart hysteria || true
else
pkill -f "hysteria.*config.yaml" || true; nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
sleep 2

# ===== [6/6] IP + v2n/Karing 修复 =====
is_private_ip() {
  case "$1" in 0.0.0.0|10.*|192.168.*|127.*|169.254.*) return 0;; 172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0;; esac
  echo "$1" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.' && return 0; return 1
}
get_pub_ip() {
  local ip; for api in https://api4.ipify.org https://icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -4fsSL --max-time 4 "$api" 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
    if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi
  done
}
if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP
else SERVER_IP=$(get_pub_ip); fi
[ -z "$SERVER_IP" ] && SERVER_IP="YOUR_PUBLIC_IP"

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
  "type": "hysteria2",
  "server": "${SERVER_IP}",
  "server_port": ${HY_PORT},
  "password": "${HY_PASS}",
  "tls": { "enabled": true, "server_name": "bing.com", "insecure": true, "alpn": ["h3"] }
}
EOF

LINK1="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Debian-Hy2-Insecure"
LINK2="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_SHA256}#Debian-Hy2-Karing"

echo -e "${GREEN}========== 完成 ==========${PLAIN}"
echo -e "IP: ${CYAN}${SERVER_IP}${PLAIN} 端口: ${CYAN}${HY_PORT}${PLAIN} 密码: ${CYAN}${HY_PASS}${PLAIN}"
echo -e "指纹: ${CYAN}${CERT_COLON}${PLAIN}"
echo -e "\n${GREEN}v2rayN 通用 (勾选允许不安全):${PLAIN}\n${LINK1}"
echo -e "\n${GREEN}Karing 推荐 (pinSHA256 更安全):${PLAIN}\n${LINK2}"
echo -e "\nClash: /etc/hysteria/clash.yaml"
echo -e "Karing JSON: /etc/hysteria/karing.json"
echo -e "证书: /etc/hysteria/cert.crt -> cat 查看内容直接复制给客户端"
