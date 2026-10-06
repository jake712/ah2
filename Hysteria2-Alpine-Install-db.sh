#!/bin/bash
# Hysteria 2 Debian V3.7 - 修复版
# 修复 Alpine -> Debian: apk->apt, openrc->systemd

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

echo -e "${GREEN}=== Hysteria2 Debian V3.7 ===${PLAIN}"

# ===== [1/6] 依赖 =====
echo -e "${YELLOW}[1/6] 检查依赖...${PLAIN}"
cat /etc/resolv.conf | head -n 5

if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "${YELLOW}检测到 Podman，保留 DNS${PLAIN}"
else
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

APT_UPDATED=0
apt_update() {
  if [ $APT_UPDATED -eq 0 ]; then
    apt-get update -qq || apt-get update
    APT_UPDATED=1
  fi
}

ensure_cmd() {
  CMD=$1
  PKG=$2
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo -e "${YELLOW}安装 $CMD ($PKG)...${PLAIN}"
    apt_update
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$PKG" || DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG"
  fi
}

if ! command -v curl >/dev/null 2>&1; then
  if ! command -v wget >/dev/null 2>&1; then
    apt_update
    apt-get install -y -qq curl || apt-get install -y curl
  fi
fi

ensure_cmd openssl openssl
if ! command -v dig >/dev/null 2>&1; then
  apt_update
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bind9-dnsutils 2>/dev/null || apt-get install -y dnsutils
fi
ensure_cmd ss iproute2
if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
  ensure_cmd update-ca-certificates ca-certificates
  update-ca-certificates 2>/dev/null || true
fi

# ===== [2/6] 参数 =====
echo -e "${YELLOW}[2/6] 初始化...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-26169}
if [ -n "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$CUSTOM_PASSWORD
else
  HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  if [ -z "$HY_PASS" ]; then
    HY_PASS="Hy2$(date +%s | tail -c 8)"
  fi
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  armv7l|arm) HY_ARCH="arm" ;;
  *) HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log
chmod 700 /etc/hysteria

# ===== [3/6] 下载 =====
echo -e "${YELLOW}[3/6] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
download_ok=0
for i in 1 2 3; do
  echo "尝试 $HY_URL 第 $i 次"
  if command -v curl >/dev/null 2>&1; then
    if curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL"; then
      download_ok=1
      break
    fi
  fi
  if command -v wget >/dev/null 2>&1; then
    if wget -q --timeout=30 -O /tmp/hysteria "$HY_URL"; then
      download_ok=1
      break
    fi
  fi
  sleep 1
done

if [ "$download_ok" != "1" ] || [ ! -s /tmp/hysteria ]; then
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    if command -v curl >/dev/null 2>&1; then
      if curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null; then
        download_ok=1
        break
      fi
    fi
    if command -v wget >/dev/null 2>&1; then
      if wget -q --timeout=30 -O /tmp/hysteria "$mirror" 2>/dev/null; then
        download_ok=1
        break
      fi
    fi
  done
fi

if [ ! -s /tmp/hysteria ]; then
  echo "下载失败"
  exit 1
fi
if head -c 200 /tmp/hysteria | grep -qi "<html"; then
  echo "下载到HTML，失败"
  exit 1
fi

mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria
/usr/local/bin/hysteria version 2>&1 || true

# ===== [4/6] 证书配置 =====
echo -e "${YELLOW}[4/6] 生成配置...${PLAIN}"
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || \
  openssl genpkey -algorithm EC -pkeyopt ec_param_enc:named_curve -pkeyopt ec_paramgen_curve:P-256 -out /etc/hysteria/key.key 2>/dev/null || \
  openssl genrsa -out /etc/hysteria/key.key 2048
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

# ===== [5/6] systemd =====
echo -e "${YELLOW}[5/6] 配置 systemd...${PLAIN}"
cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria 2 V3.7 Debian
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable hysteria >/dev/null 2>&1 || true
  systemctl restart hysteria || systemctl start hysteria
  sleep 2
  systemctl status hysteria --no-pager -l | head -n 20 || true
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi

cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/bash
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl restart hysteria
else
  pkill -f "hysteria.*config.yaml" || true
  sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh

# ===== [6/6] IP检测 =====
echo -e "${YELLOW}[6/6] IP检测...${PLAIN}"
is_private_ip() {
  local ip=$1
  if [ -z "$ip" ]; then return 0; fi
  case "$ip" in
    0.0.0.0|10.*|192.168.*|127.*|169.254.*) return 0 ;;
    172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;;
  esac
  echo "$ip" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.' && return 0
  return 1
}
get_ssh_ip() {
  if [ -n "$SSH_CONNECTION" ]; then echo "$SSH_CONNECTION" | awk '{print $3}'; return; fi
  ss -tn 2>/dev/null | grep ':22' | awk '{print $4}' | cut -d: -f1 | grep -E '^[0-9.]+$' | grep -v '^127\.' | head -n1
}
get_pub_ip() {
  local ip
  if command -v dig >/dev/null 2>&1; then
    for ns in 208.67.222.222 8.8.8.8 1.1.1.1; do
      ip=$(dig +short +time=2 +tries=1 @${ns} myip.opendns.com 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
      if [ -n "$ip" ]; then
        if ! is_private_ip "$ip"; then echo "$ip"; return; fi
      fi
    done
  fi
  if command -v curl >/dev/null 2>&1; then
    for api in https://api4.ipify.org https://ifconfig.me/ip https://ip.sb; do
      ip=$(curl -4fsSL --max-time 4 "$api" 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
      if [ -n "$ip" ]; then
        if ! is_private_ip "$ip"; then echo "$ip"; return; fi
      fi
    done
  fi
}

if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP
else
  SIP=$(get_ssh_ip)
  PIP=$(get_pub_ip)
  echo -e "SSH IP: ${YELLOW}${SIP:-无}${PLAIN}  公网: ${YELLOW}${PIP:-无}${PLAIN}"
  if [ -z "$SIP" ]; then
    if [ -n "$PIP" ]; then SERVER_IP=$PIP; fi
  else
    if is_private_ip "$SIP"; then SERVER_IP=${PIP:-$SIP}; else SERVER_IP=${SIP:-$PIP}; fi
  fi
fi
if [ -z "$SERVER_IP" ]; then SERVER_IP="YOUR_PUBLIC_IP"; fi

echo -e "${GREEN}========== 完成 ==========${PLAIN}"
echo -e "端口: ${CYAN}${HY_PORT}${PLAIN}  密码: ${CYAN}${HY_PASS}${PLAIN}  IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Debian-Hy2-V3.7${PLAIN}"
echo -e "重启: systemctl restart hysteria"
