#!/bin/sh
# Hysteria 2 Alpine V1.5 - 端口跳跃版 (支持 VPS 区域感知 + 智能优选 SNI + 端口跳跃)
# 适配: Alpine Linux 3.20/3.21/3.22+, Karing 客户端完美适配版

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

CUSTOM_PORT=""
CUSTOM_PASSWORD=""
CUSTOM_IP=""
CUSTOM_SNI=""

while getopts "p:w:i:s:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    s) CUSTOM_SNI=$OPTARG ;;
    h) echo "用法: $0 [-p 端口或端口段,如 20000-30000] [-w 认证密码] [-i 公网IP] [-s 自定义SNI域名]"; exit 0 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

echo -e "${GREEN}=== Hysteria2 Alpine V1.5 端口跳跃版 (区域感知与智能优选SNI) ===${PLAIN}"
echo -e "容器ID: $(cat /etc/hostname 2>/dev/null || hostname) | 时间: $(date) | 系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2)"

# ===== [1/5] 基础依赖 - Alpine适配 =====
echo -e "${YELLOW}[1/5] 检查并安装 Alpine 依赖...${PLAIN}"

if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "${YELLOW}检测到 Podman (dns.podman)，保留原有 DNS${PLAIN}"
else
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo -e "${YELLOW}修复 DNS...${PLAIN}"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

if ! command -v apk >/dev/null 2>&1; then
  echo -e "${RED}未检测到 apk，不是 Alpine Linux 系统${PLAIN}"; exit 1
fi

echo -e "${YELLOW}更新 apk 软件源并安装必要工具...${PLAIN}"
apk update -q
apk add --no-cache curl openssl bind-tools iproute2 ca-certificates iptables

if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
  update-ca-certificates 2>/dev/null || true
fi

# ===== [2/5] 参数和端口跳跃初始化 =====
echo -e "${YELLOW}[2/5] 初始化端口与跳跃规则...${PLAIN}"
HY_PORT_INPUT=${CUSTOM_PORT:-30000}

# 判断是否为端口段（支持 - 或 : 分隔，如 20000-30000）
if echo "$HY_PORT_INPUT" | grep -qE '[-:]'; then
  HOP_ENABLED=1
  HOP_RANGE=$(echo "$HY_PORT_INPUT" | tr ':' '-')
  HOP_START=$(echo "$HOP_RANGE" | cut -d'-' -f1)
  HOP_END=$(echo "$HOP_RANGE" | cut -d'-' -f2)
  INTERNAL_PORT=$HOP_START
  HY_PORT="$HOP_RANGE"
  echo -e "${GREEN}✔ 已启用端口跳跃模式: 外部端口段 [${HOP_START} - ${HOP_END}] -> 内部服务端口 [${INTERNAL_PORT}]${PLAIN}"
else
  HOP_ENABLED=0
  INTERNAL_PORT="$HY_PORT_INPUT"
  HY_PORT="$HY_PORT_INPUT"
  echo -e "${GREEN}✔ 单端口模式: 端口 [${HY_PORT}]${PLAIN}"
fi

# 随机生成混淆密码和认证密码
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

mkdir -p /etc/hysteria /usr/local/bin /var/log
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

# ===== [4/5] VPS 区域感知与智能测速优选 SNI =====
echo -e "${YELLOW}[4/5] 正在识别 VPS 归属地并智能优选 SNI...${PLAIN}"

if [ -n "$CUSTOM_SNI" ]; then
  OPTIMIZED_SNI="$CUSTOM_SNI"
  echo -e "${GREEN}✔ 使用用户指定的自定义 SNI: ${OPTIMIZED_SNI}${PLAIN}"
else
  GEO_COUNTRY=$(curl -4s --max-time 3 ipinfo.io/country 2>/dev/null || echo "UNKNOWN")
  echo -e "${CYAN}当前 VPS 归属地检测: [ ${GEO_COUNTRY} ]${PLAIN}"

  case "$GEO_COUNTRY" in
    HK|SG|TW|MO)
      SNI_CANDIDATES="cp.cloudflare.com speed.cloudflare.com gateway.icloud.com time.apple.com"
      ;;
    JP|KR)
      SNI_CANDIDATES="dl.google.com update.googleapis.com cp.cloudflare.com www.msftconnecttest.com"
      ;;
    US|CA|DE|GB|FR)
      SNI_CANDIDATES="www.msftconnecttest.com ctldl.windowsupdate.com time.apple.com cp.cloudflare.com"
      ;;
    *)
      SNI_CANDIDATES="www.msftconnecttest.com cp.cloudflare.com connectivitycheck.gstatic.com time.apple.com"
      ;;
  esac

  OPTIMIZED_SNI="www.msftconnecttest.com"
  LOWEST_LATENCY=9999

  for domain in $SNI_CANDIDATES; do
    latency=$(curl -o /dev/null -s -w '%{time_connect}\n' --connect-timeout 2 -m 3 "https://$domain" 2>/dev/null || echo "999")
    is_better=$(awk -v l="$latency" -v min="$LOWEST_LATENCY" 'BEGIN {if (l > 0 && l < min) print 1; else print 0}')
    if [ "$is_better" = "1" ]; then
      LOWEST_LATENCY=$latency
      OPTIMIZED_SNI=$domain
    fi
  done
  echo -e "${GREEN}✔ 区域适配优选最佳 SNI: ${OPTIMIZED_SNI} (节点延迟: ${LOWEST_LATENCY}s)${PLAIN}"
fi

if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=${OPTIMIZED_SNI}" -days 3650 2>/dev/null
  chmod 600 /etc/hysteria/key.key
fi

# 写入配置文件（监听内部端口）
cat > /etc/hysteria/config.yaml <<EOF
listen: :${INTERNAL_PORT}

auth:
  type: password
  password: ${HY_PASS}

obfs:
  type: salamander
  salamander:
    password: ${HY_OBFS_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://${OPTIMIZED_SNI}
    rewriteHost: true

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
EOF

# ===== [5/5] 防火墙、服务配置与启动 =====
echo -e "${YELLOW}[5/5] 配置 iptables 规则并启动服务...${PLAIN}"

# 配置 iptables 规则
if [ "$HOP_ENABLED" = "1" ]; then
  iptables -t nat -D PREROUTING -p udp --dport ${HOP_START}:${HOP_END} -j REDIRECT --to-ports ${INTERNAL_PORT} 2>/dev/null || true
  iptables -t nat -A PREROUTING -p udp --dport ${HOP_START}:${HOP_END} -j REDIRECT --to-ports ${INTERNAL_PORT}
  iptables -D INPUT -p udp --dport ${HOP_START}:${HOP_END} -j ACCEPT 2>/dev/null || true
  iptables -A INPUT -p udp --dport ${HOP_START}:${HOP_END} -j ACCEPT
else
  iptables -D INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || true
  iptables -A INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || true
fi

# 保存 iptables 规则（Alpine 兼容）
if command -v rc-service >/dev/null 2>&1 && [ -d /etc/init.d/iptables ]; then
  rc-update add iptables default >/dev/null 2>&1 || true
  /etc/init.d/iptables save >/dev/null 2>&1 || true
fi

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

if command -v openrc >/dev/null 2>&1 && [ -d /etc/init.d ]; then
  cat > /etc/init.d/hysteria <<EOF
#!/sbin/openrc-run

name="Hysteria2 Server"
description="Hysteria2 Server (Port Hopping)"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria.pid"

depend() {
  use net
  after firewall
}
EOF
  chmod +x /etc/init.d/hysteria
  rc-update add hysteria default >/dev/null 2>&1 || true
  rc-service hysteria restart >/dev/null 2>&1 || rc-service hysteria start >/dev/null 2>&1 || true
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true
  sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi

SERVER_IP=$CUSTOM_IP
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 5 api.ipify.org || curl -4s --max-time 5 ifconfig.me || echo "你的服务器IP")
fi

echo -e "\n${GREEN}================================================"
echo -e "Hysteria 2 节点部署成功！(端口跳跃与区域优选版)"
echo -e "================================================${PLAIN}"
echo -e "${CYAN}[Karing 客户端手动填入参数]:${PLAIN}"
echo -e "  - ${YELLOW}服务器地址 (Address):${PLAIN} ${SERVER_IP}"
echo -e "  - ${YELLOW}端口 (Port):${PLAIN} ${HY_PORT}"
echo -e "  - ${YELLOW}认证密码 (Password):${PLAIN} ${HY_PASS}"
echo -e "  - ${YELLOW}混淆类型 (Obfs Type):${PLAIN} salamander"
echo -e "  - ${YELLOW}混淆密码 (Obfs Password):${PLAIN} ${HY_OBFS_PASS}"
echo -e "  - ${YELLOW}SNI / 伪装域名:${PLAIN} ${OPTIMIZED_SNI}"
echo -e "  - ${YELLOW}允许跳过证书验证 (Insecure):${PLAIN} 开启 (True)"
echo -e "------------------------------------------------"
echo -e "${CYAN}[标准 Hysteria2 节点链接]:${PLAIN}"
echo -e "  hy2://${HY_PASS}@${SERVER_IP}:${HY_PORT}?insecure=1&sni=${OPTIMIZED_SNI}&obfs=salamander&obfs-password=${HY_OBFS_PASS}"
echo -e "================================================${PLAIN}"
