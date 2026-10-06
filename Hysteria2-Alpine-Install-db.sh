#!/bin/bash
# Hysteria 2 Debian V3.7 - 取消默认26169版
# 修改点: 原来 HY_PORT=${CUSTOM_PORT:-26169} 已取消，改为未指定则随机端口
# 基于 jake712 V3.7 修复 dig + curl -4 问题

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
echo -e "容器ID: $(cat /etc/hostname 2>/dev/null || hostname) | 时间: $(date)"

# ===== [1/6] 基础依赖 =====
echo -e "${YELLOW}[1/6] 检查依赖...${PLAIN}"
cat /etc/resolv.conf | head -n 5
cat /proc/meminfo 2>/dev/null | grep -E "MemTotal|MemAvailable" || free -m 2>/dev/null || true

if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "${YELLOW}检测到 Podman (dns.podman)，保留原有 DNS${PLAIN}"
else
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo -e "${YELLOW}修复 DNS...${PLAIN}"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

APT_UPDATED=0
apt_update() {
  if [ $APT_UPDATED -eq 0 ]; then
    echo -e "${YELLOW}更新 apt 源...${PLAIN}"
    apt-get update -qq || apt-get update
    APT_UPDATED=1
  fi
}

ensure_cmd() {
  CMD=$1
  PKG=$2
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo -e "${YELLOW}安装缺失: $CMD ($PKG)...${PLAIN}"
    apt_update
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$PKG" 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG" 2>&1
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
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bind9-dnsutils 2>/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils 2>/dev/null
fi
ensure_cmd ss iproute2
if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
  ensure_cmd update-ca-certificates ca-certificates
  update-ca-certificates 2>/dev/null || true
fi

# ===== [2/6] 参数和路径 - 已取消默认26169 =====
echo -e "${YELLOW}[2/6] 初始化参数 (已取消默认26169)...${PLAIN}"

# 关键修改：取消默认 26169
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
  if command -v openssl >/dev/null 2>&1; then
    HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  else
    HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
  fi
fi
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  armv7l|arm) HY_ARCH="arm" ;;
  *) HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log
chmod 700 /etc/hysteria 2>/dev/null || true

# ===== [3/6] 下载 Hysteria2 =====
echo -e "${YELLOW}[3/6] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
download_ok=0
for i in 1 2 3; do
  echo "尝试下载 $HY_URL (第 $i 次)"
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
  echo -e "${YELLOW}尝试备用镜像...${PLAIN}"
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    if command -v curl >/dev/null 2>&1; then
      curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
    fi
    if command -v wget >/dev/null 2>&1; then
      wget -q --timeout=30 -O /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
    fi
  done
fi

if [ ! -s /tmp/hysteria ]; then
  echo -e "${RED}下载失败${PLAIN}"
  exit 1
fi
if head -c 200 /tmp/hysteria 2>/dev/null | grep -qi "<html"; then
  echo -e "${RED}下载到HTML页面，失败${PLAIN}"
  exit 1
fi

mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria
/usr/local/bin/hysteria version 2>&1 || true

# ===== [4/6] 生成证书和配置 =====
echo -e "${YELLOW}[4/6] 生成配置...${PLAIN}"
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || \
  openssl genpkey -algorithm EC -pkeyopt ec_param_enc:named_curve -pkeyopt ec_paramgen_curve:P-256 -out /etc/hysteria/key.key 2>/dev/null || \
  openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650 2>/dev/null || \
  openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
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

# ===== [5/6] 服务 - Debian systemd =====
echo -e "${YELLOW}[5/6] 配置 systemd...${PLAIN}"
cat
