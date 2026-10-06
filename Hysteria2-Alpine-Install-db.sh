#!/bin/bash
# Hysteria 2 Debian V3.7 - 取消默认26169版 - 修复systemd在Podman容器中直接退出导致无分享链接的问题

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

while getopts "p:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 端口] [-w 密码] [-i 公网IP]"; echo "  不指定-p 将随机生成端口，不再默认26169"; exit 0 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}请用 root 运行${PLAIN}"
  exit 1
fi

echo -e "${GREEN}=== Hysteria2 Debian V3.7 取消默认端口版 ===${PLAIN}"

# ===== [1/6] 基础依赖 =====
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
  CMD=$1; PKG=$2
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo -e "${YELLOW}安装 $CMD ($PKG)...${PLAIN}"
    apt_update
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$PKG" 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG" 2>&1 || true
  fi
}

if ! command -v curl >/dev/null 2>&1; then
  if ! command -v wget >/dev/null 2>&1; then
    apt_update
    apt-get install -y -qq curl 2>/dev/null || apt-get install -y curl 2>/dev/null || true
  fi
fi

ensure_cmd openssl openssl
if ! command -v dig >/dev/null 2>&1; then
  apt_update
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bind9-dnsutils 2>/dev/null || apt-get install -y dnsutils 2>/dev/null || true
fi
ensure_cmd ss iproute2

if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
  ensure_cmd update-ca-certificates ca-certificates
  update-ca-certificates 2>/dev/null || true
fi

# ===== [2/6] 参数 - 取消默认26169 =====
echo -e "${YELLOW}[2/6] 初始化参数 (已取消默认26169)...${PLAIN}"

if [ -z "$CUSTOM_PORT" ]; then
  if command -v shuf >/dev/null 2>&1; then
    HY_PORT=$(shuf -i 20000-60000 -n 1)
  else
    HY_PORT=$((RANDOM % 40000 + 20000))
  fi
  echo -e "${YELLOW}未指定 -p，已随机生成端口: ${CYAN}${HY_PORT}${PLAIN}"
else
  HY_PORT=$CUSTOM_PORT
  echo -e "使用指定端口: ${CYAN}${HY_PORT}${PLAIN}"
fi

if [ -n "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$CUSTOM_PASSWORD
else
  HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  [ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  *) HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log
chmod 700 /etc/hysteria 2>/dev/null || true

# ===== [3/6] 下载 =====
echo -e "${YELLOW}[3/6] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
download_ok=0
for i in 1 2 3; do
  echo "尝试下载 $HY_URL (第 $i 次)"
  if command -v curl >/dev/null 2>&1; then
    curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" 2>/dev/null && download_ok=1 && break
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q --timeout=30 -O /tmp/hysteria "$HY_URL" 2>/dev/null && download_ok=1 && break
  fi
  sleep 1
done

if [ "$download_ok" != "1" ] || [ ! -s /tmp/hysteria ]; then
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
    wget -q --timeout=30 -O /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
  done
fi

if [ ! -s /tmp/hysteria ]; then echo -e "${RED}下载失败${PLAIN}"; exit 1; fi
mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria
/usr/local/bin/hysteria version 2>&1 || true

# ===== [4/6] 配置 =====
echo -e "${YELLOW}[4/6] 生成配置...${PLAIN}"
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650 2>/dev/null
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

cat /etc/hysteria/config.yaml

# ===== [5/6] 服务 - 修复版容错 =====
echo -e "${YELLOW}[5/6] 配置服务...${PLAIN}"

# 先杀掉旧进程，避免端口占用
pkill -9 hysteria 2>/dev/null || true
sleep 1

cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria 2 Debian V3.7 NoDefaultPort
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

# 关键修复：所有 systemctl 加 || true，防止 set -e 直接退出
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  echo "检测到 systemd，尝试 systemctl..."
  systemctl daemon-reload || true
  systemctl enable hysteria >/dev/null 2>&1 || true
  systemctl restart hysteria 2>&1 || systemctl start hysteria 2>&1 || true
  sleep 2
  systemctl status hysteria --no-pager -l 2>&1 | head -n 20 || true
else
  echo -e "${YELLOW}未检测到 systemd (Podman容器)，使用 nohup 后台运行...${PLAIN}"
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
  sleep 2
fi

cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/bash
pkill -f "hysteria.*config.yaml" 2>/dev/null || true
sleep 1
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl restart hysteria 2>&1 || nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
else
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
echo "已重启"
ss -unlp 2>/dev/null | grep hysteria || ss -tulpn 2>/dev/null | grep hysteria || cat /var/log/hysteria.log | tail -n 20
RESTART
chmod +x /usr/local/bin/hy2-restart.sh

ss -unlp 2>/dev/null | grep -E "$HY_PORT|hysteria" || ss -tulpn 2>/dev/null | grep -E "$HY_PORT|hysteria" || echo "端口检查稍后..."
tail -n 20 /var/log/hysteria.log 2>/dev/null || journalctl -u hysteria -n 20 --no-pager 2>/dev/null || true

# ===== [6/6] IP检测 =====
echo -e "${YELLOW}[6/6] IP检测...${PLAIN}"

is_private_ip() {
  local ip=$1
  [ -z "$ip" ] && return 0
  case "$ip" in 0.0.0.0|10.*|192.168.*|127.*|169.254.*) return 0 ;; 172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;; esac
  echo "$ip" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.' && return 0
  return 1
}
get_pub_ip() {
  local ip
  if command -v dig >/dev/null 2>&1; then
    for ns in 208.67.222.222 8.8.8.8; do
      ip=$(dig +short +time=2 +tries=1 @${ns} myip.opendns.com 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
      [ -n "$ip" ] && ! is_private_ip "$ip" && echo "$ip" && return
    done
  fi
  if command -v curl >/dev/null 2>&1; then
    for api in https://api4.ipify.org https://ifconfig.me/ip; do
      ip=$(curl -4fsSL --max-time 4 "$api" 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
      [ -n "$ip" ] && ! is_private_ip "$ip" && echo "$ip" && return
    done
  fi
}

if [ -n "$CUSTOM_IP" ]; then
  SERVER_IP=$CUSTOM_IP
  echo -e "${GREEN}手动指定 -i: $SERVER_IP${PLAIN}"
else
  PIP=$(get_pub_ip)
  echo -e "出口公网IP: ${YELLOW}${PIP:-未知}${PLAIN}"
  SERVER_IP=${PIP:-YOUR_PUBLIC_IP}
fi

echo ""
echo -e "${GREEN}========== V3.7 Debian 取消默认端口版完成 ==========${PLAIN}"
echo -e "端口: ${CYAN}${HY_PORT}${PLAIN} (已取消固定26169)"
echo -e "密码: ${CYAN}${HY_PASS}${PLAIN}"
echo -e "IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo ""
echo -e "分享链接:"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Debian-Hy2-NoDefault-${HY_PORT}${PLAIN}"
echo ""
echo -e "日志: tail -f /var/log/hysteria.log 或 journalctl -u hysteria -f"
echo -e "重启: /usr/local/bin/hy2-restart.sh"
echo -e "放行: ufw allow ${HY_PORT}/udp"
echo -e "检查: ss -unlp | grep ${HY_PORT}"
