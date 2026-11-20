#!/bin/sh
# =========================================================================
# Hysteria 2 Alpine 终极隐蔽增强版 (单端口 + 动态随机端口 + 进程伪装 + 智能优选SNI)
# 适配: Alpine Linux 3.20/3.21/3.22+, Podman / Docker 容器及原生系统
# =========================================================================

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
    h) 
      echo "用法: $0 [选项]"
      echo "  -p <端口>       自定义监听端口 (不填则随机生成高位端口)"
      echo "  -w <密码>       自定义认证密码 (不填则随机生成)"
      echo "  -i <公网IP>     手动指定服务器公网 IP"
      echo "  -s <SNI域名>    自定义 TLS SNI / 伪装域名"
      echo "  -h              查看帮助信息"
      exit 0 
      ;;
  esac
done

if [ "$(id -u)" != "0" ]; then 
  echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
  exit 1 
fi

echo -e "${GREEN}=== Hysteria2 Alpine 终极隐蔽增强版部署开始 ===${PLAIN}"

# ===== [1/5] 基础依赖检查与修复 =====
echo -e "${YELLOW}[1/5] 检查并配置 Alpine 系统环境...${PLAIN}"
if ! grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
  fi
fi

if ! command -v apk >/dev/null 2>&1; then
  echo -e "${RED}错误: 未检测到 apk 包管理器，本脚本仅支持 Alpine Linux 系统${PLAIN}"
  exit 1
fi

apk update -q
apk add --no-cache curl openssl ca-certificates gawk iproute2

# ===== [2/5] 端口与密码初始化 =====
echo -e "${YELLOW}[2/5] 初始化通信参数与安全密钥...${PLAIN}"
if [ -n "$CUSTOM_PORT" ]; then
  HY_PORT=$CUSTOM_PORT
else
  # 随机生成 10000 至 55000 间的高位随机端口，避开特征扫描
  HY_PORT=$(awk 'BEGIN{srand(); print int(rand()*(55000-10000+1))+10000}')
  echo -e "${CYAN}✔ 未指定端口，已自动生成动态随机端口: ${HY_PORT}${PLAIN}"
fi

HY_OBFS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
if [ -n "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$CUSTOM_PASSWORD
else
  HY_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  armv7l|arm) HY_ARCH="arm" ;;
  *) HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /var/log
chmod 700 /etc/hysteria

# ===== [3/5] 下载二进制并实现进程特征伪装 =====
echo -e "${YELLOW}[3/5] 下载核心组件并进行进程名伪装...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria

download_success=0
for url in "$HY_URL" "https://ghfast.top/$HY_URL"; do
  if curl -fsSL --max-time 30 -o /tmp/hysteria "$url"; then
    download_success=1
    break
  fi
done

if [ "$download_success" != "1" ] || [ ! -s /tmp/hysteria ]; then
  echo -e "${RED}错误: Hysteria2 核心下载失败，请检查网络连接${PLAIN}"
  exit 1
fi

# 核心安全机制：将二进制重命名为系统守护进程名，混淆 ps 进程检查
DISGUISE_NAME="systemd-timesyncd"
mv /tmp/hysteria /usr/local/bin/$DISGUISE_NAME
chmod +x /usr/local/bin/$DISGUISE_NAME

# ===== [4/5] VPS 区域感知、SNI 优选与配置生成 =====
echo -e "${YELLOW}[4/5] 正在执行区域感知与最优 SNI 测速优选...${PLAIN}"

if [ -n "$CUSTOM_SNI" ]; then
  OPTIMIZED_SNI="$CUSTOM_SNI"
  echo -e "${GREEN}✔ 使用自定义指定的 SNI 域名: ${OPTIMIZED_SNI}${PLAIN}"
else
  GEO_COUNTRY=$(curl -s --max-time 3 ipinfo.io/country 2>/dev/null || echo "UNKNOWN")
  echo -e "${CYAN}当前 VPS 归属地识别: [ ${GEO_COUNTRY} ]${PLAIN}"

  case "$GEO_COUNTRY" in
    HK|SG|TW|MO) SNI_CANDIDATES="www.apple.com www.cloudflare.com gateway.icloud.com" ;;
    JP|KR)       SNI_CANDIDATES="www.apple.com dl.google.com www.microsoft.com" ;;
    *)           SNI_CANDIDATES="www.bing.com www.apple.com www.cloudflare.com" ;;
  esac

  OPTIMIZED_SNI="www.bing.com"
  LOWEST_LATENCY=9999

  for domain in $SNI_CANDIDATES; do
    latency=$(curl -o /dev/null -s -w '%{time_connect}\n' --connect-timeout 2 -m 3 "https://$domain" 2>/dev/null || echo "999")
    is_better=$(awk -v l="$latency" -v min="$LOWEST_LATENCY" 'BEGIN {if (l > 0 && l < min) print 1; else print 0}')
    if [ "$is_better" = "1" ]; then
      LOWEST_LATENCY=$latency
      OPTIMIZED_SNI=$domain
    fi
  done
  echo -e "${GREEN}✔ 智能优选最佳 SNI: ${OPTIMIZED_SNI} (延迟: ${LOWEST_LATENCY}s)${PLAIN}"
fi

# 每次部署强制刷新自签名证书以完美匹配 SNI 域名
rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null
openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=${OPTIMIZED_SNI}" -days 3650 2>/dev/null
chmod 600 /etc/hysteria/key.key

# 写入标准严格缩进的 YAML 配置文件
cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}

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

# ===== [5/5] 服务启动与地址解析 =====
echo -e "${YELLOW}[5/5] 启动隐蔽服务进程...${PLAIN}"
pkill -x "$DISGUISE_NAME" 2>/dev/null || true
sleep 1
nohup /usr/local/bin/$DISGUISE_NAME server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &

# 获取公网 IP (兼容 IPv4 及 IPv6 兜底)
SERVER_IP=$CUSTOM_IP
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 4 api.ipify.org || curl -4s --max-time 4 ifconfig.me || true)
  if [ -z "$SERVER_IP" ]; then
    IPV6=$(curl -6s --max-time 4 api64.ipify.org || true)
    [ -n "$IPV6" ] && SERVER_IP="[${IPV6}]" || SERVER_IP="YOUR_SERVER_IP"
  fi
fi

echo -e "\n${GREEN}================================================================${PLAIN}"
echo -e "${GREEN}🎉 Hysteria 2 终极隐蔽增强版部署成功！${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e " 📍 服务器地址 (Address) : ${CYAN}${SERVER_IP}${PLAIN}"
echo -e " 🔢 动态监听端口 (Port)   : ${CYAN}${HY_PORT}${PLAIN}"
echo -e " 🔑 认证密码 (Password)   : ${CYAN}${HY_PASS}${PLAIN}"
echo -e " 🕵️ 伪装进程名 (Process)  : ${CYAN}${DISGUISE_NAME}${PLAIN}"
echo -e " 🛡️ 混淆类型 (Obfs)       : ${CYAN}salamander (${HY_OBFS_PASS})${PLAIN}"
echo -e " 🌐 伪装域名 (SNI)        : ${CYAN}${OPTIMIZED_SNI}${PLAIN}"
echo -e "----------------------------------------------------------------"
echo -e "${YELLOW}[Karing / 客户端标准直连链接]:${PLAIN}"
echo -e "${CYAN}hy2://${HY_PASS}@${SERVER_IP}:${HY_PORT}?insecure=1&sni=${OPTIMIZED_SNI}&obfs=salamander&obfs-password=${HY_OBFS_PASS}#Hy2-Stealth-${GEO_COUNTRY:-Node}${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
