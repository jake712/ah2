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
  CMD=$1; PKG=$2
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo -e "${YELLOW}安装 $CMD ($PKG)...${PLAIN}"
    apt_update
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$PKG" || DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG"
  fi
}

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  apt_update; apt-get install -y -qq curl || apt-get install -y curl
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
  [ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"
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
    curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" && download_ok=1 && break
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q --timeout=30 -O /tmp/hysteria "$HY_URL" && download_ok=1 && break
  fi
  sleep 1
done

if [ "$download_ok" != "1" ] || [ ! -s /tmp/hysteria ]; then
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" "https://ghproxy.net/https://github.com/apernet
