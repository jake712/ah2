#!/bin/sh
# Hysteria 2 Alpine V1.1 - NAT/Podman/LXC 高级防封锁增强版 (多端口跳动/端口跳跃专用版)
# 适配: Alpine Linux 3.15+, Karing 客户端完美适配版

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

while getopts "p:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 端口范围，如 30000-35000] [-w 认证密码] [-i 公网IP]"; exit 0 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

echo -e "${GREEN}=== Hysteria2 Alpine V1.1 Karing多端口跳动防封锁版 ===${PLAIN}"
echo -e "容器ID: $(cat /etc/hostname 2>/dev/null || hostname) | 时间: $(date) | 系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2)"

# ===== [1/5] 基础依赖 - Alpine适配 =====
echo -e "${YELLOW}[1/5] 检查依赖 (Alpine 极速模式)...${PLAIN}"

if ! command -v apk >/dev/null 2>&1; then
  echo -e "${RED}未检测到 apk，不是 Alpine Linux 系统${PLAIN}"; exit 1
fi

APK_UPDATED=0
apk_update() {
  if [ $APK_UPDATED -eq 0 ]; then
    echo -e "${YELLOW}apk update...${PLAIN}"
    apk update -q
    APK_UPDATED=1
  fi
}

ensure_cmd() {
  CMD=$1
  PKG=$2
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo -e "${YELLOW}安装缺失: $CMD ($PKG)...${PLAIN}"
    apk_update
    apk add --no-cache "$PKG" 2>&1 || echo -e "${RED}安装 $PKG 失败...${PLAIN}"
  fi
}

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  apk_update
  apk add --no-cache curl 2>&1 || true
fi

ensure_cmd openssl openssl
ensure_cmd dig bind-tools
ensure_cmd ss iproute2
ensure_cmd update-ca-certificates ca-certificates
ensure_cmd shuf coreutils

# ===== [2/5] 参数和路径 =====
echo -e "${YELLOW}[2/5] 初始化参数...${PLAIN}"
# 默认端口跳跃范围改为了 30000-35000 (可根据需要通过 -p 传入)
HY_PORT=${CUSTOM_PORT:-30000-35000}

# 随机生成 Karing 所需的混淆密码 (obfs password)
if command -v openssl >/dev/null 2>&1; then
  HY_OBFS_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  [ -z "$CUSTOM_PASSWORD" ] && HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
else
  HY_OBFS_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
  [ -z "$CUSTOM_PASSWORD" ] && HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
fi
[ -n "$CUSTOM_PASSWORD" ] && HY_PASS=$CUSTOM_PASSWORD
[ -z "$HY_PASS" ] && HY_PASS="Hy2Pass$(date +%s | tail -c 4)"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  armv7l|arm) HY_ARCH="arm" ;;
  *) HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log
chmod 700 /etc/hysteria 2>/dev/null || true

# ===== [3/5] 下载 Hysteria2 =====
echo -e "${YELLOW}[3/5] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
download_ok=0
for i in 1 2 3; do
  if command -v curl >/dev/null 2>&1; then
    if curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL"; then download_ok=1; break; fi
  fi
  sleep 1
done

if [ "$download_ok" != "1" ]; then
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
  done
fi

if [ ! -s /tmp/hysteria ]; then echo -e "${RED}下载失败${PLAIN}"; exit 1; fi
mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

# ===== [4/5] 生成随机伪装证书和高级配置 =====
echo -e "${YELLOW}[4/5] 生成防封锁混淆配置...${PLAIN}"

# 伪装域名随机池，拒绝单一特征
DOMAINS="apple.com cloudflare.com icloud.com microsoft.com windows.com weather.com"
RANDOM_SNI=$(echo "$DOMAINS" | tr ' ' '\n' | shuf -n 1 2>/dev/null || echo "cloudflare.com")

if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=${RANDOM_SNI}" -days 3650 2>/dev/null
  chmod 600 /etc/hysteria/key.key
fi

# 写入配置文件 (已启用多端口范围监听)
cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}

auth:
  type: password
  password: ${HY_PASS}

# 流量混淆配置 (Karing完美适配)
obfs:
  type: salamander
  salamander:
    password: ${HY_OBFS_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://${RANDOM_SNI}
    rewriteHost: true

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
EOF

# ===== [5/5] 服务 - Alpine OpenRC/Background 兼容 =====
echo -e "${YELLOW}[5/5] 配置并启动服务...${PLAIN}"

cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
pkill -f "hysteria.*config.yaml" || true
sleep 1
if command -v rc-service >/dev/null 2>&1 && rc-service hysteria status >/dev/null 2>&1; then
  rc-service hysteria restart
else
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh

if [ -d /etc/init.d ] && command -v openrc >/dev/null 2>&1; then
  cat > /etc/init.d/hysteria <<'INIT'
#!/sbin/openrc-run

name="hysteria"
description="Hysteria2 Server (Karing Port Hopping Enhanced)"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria.pid"

depend() {
    need net
    after firewall
}
INIT
  chmod +x /etc/init.d/hysteria
  rc-update add hysteria default >/dev/null 2>&1 || true
  rc-service hysteria restart >/dev/null 2>&1 || true
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true
  sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi

# 输出 Karing 专用配置
SERVER_IP=$CUSTOM_IP
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 5 api.ipify.org || curl -4s --max-time 5 ifconfig.me || echo "你的服务器IP")
fi

# 提取端口范围的起始端口用于主端口顯示
BASE_PORT=$(echo "$HY_PORT" | cut -d'-' -f1)

echo -e "\n${GREEN}================================================"
echo -e "Hysteria 2 多端口跳动节点部署成功！(Alpine 端口跳跃版)"
echo -e "================================================${PLAIN}"
echo -e "${CYAN}[Karing 客户端手动填入参数]:${PLAIN}"
echo -e "  - ${YELLOW}服务器地址 (Address):${PLAIN} ${SERVER_IP}"
echo -e "  - ${YELLOW}主端口 / 起始端口 (Port):${PLAIN} ${BASE_PORT} (或填入范围起始)"
echo -e "  - ${YELLOW}端口跳跃范围 (Port Hopping / mport):${PLAIN} ${HY_PORT}"
echo -e "  - ${YELLOW}认证密码 (Password):${PLAIN} ${HY_PASS}"
echo -e "  - ${YELLOW}混淆类型 (Obfs Type):${PLAIN} salamander"
echo -e "  - ${YELLOW}混淆密码 (Obfs Password):${PLAIN} ${HY_OBFS_PASS}"
echo -e "  - ${YELLOW}SNI / 伪装域名:${PLAIN} ${RANDOM_SNI}"
echo -e "  - ${YELLOW}允许跳过证书验证 (Insecure):${PLAIN} 开启 (True)"
echo -e "------------------------------------------------"
echo -e "${CYAN}[标准 Hysteria2 节点链接 (已包含 mport 范围)]:${PLAIN}"
apk add --no-cache iptables && rc-service hysteria restart
echo -e "  hy2://${HY_PASS}@${SERVER_IP}:${BASE_PORT}?mport=${HY_PORT}&insecure=1&sni=${RANDOM_SNI}&obfs=salamander&obfs-password=${HY_OBFS_PASS}"
echo -e "================================================${PLAIN}"
