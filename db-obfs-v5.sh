#!/bin/sh
# =========================================================================
# Hysteria 2 + AnyTLS Debian 同端口终极完美版部署脚本
# 适配: Debian 11/12+ (AMD64 / ARM64)
# =========================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

CUSTOM_PORT=""
CUSTOM_IP=""

while getopts "p:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h)
      echo "用法: $0 [选项]"
      echo "  -p <端口>   自定义监听端口 (默认随机高位端口)"
      echo "  -i <公网IP> 手动指定服务器公网 IP"
      exit 0
      ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
  exit 1
fi

echo -e "${GREEN}=== 开始部署 Hysteria 2 + AnyTLS (Debian 同端口双协议完美版) ===${PLAIN}"

# ===== [1/5] 基础环境与依赖 =====
echo -e "${YELLOW}[1/5] 检查并配置系统环境...${PLAIN}"
if ! grep -q "nameserver" /etc/resolv.conf 2>/dev/null; then
  echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo -e "${RED}错误: 未检测到 apt-get 包管理器，本脚本仅支持 Debian / Ubuntu 系统${PLAIN}"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates gawk iproute2 unzip >/dev/null 2>&1

# ===== [2/5] 端口与密钥初始化 =====
echo -e "${YELLOW}[2/5] 正在初始化端口与安全密钥...${PLAIN}"
if [ -n "$CUSTOM_PORT" ]; then
  PORT=$CUSTOM_PORT
  echo -e "${CYAN}✔ 使用用户指定的端口: ${PORT}${PLAIN}"
else
  PORT=$(awk 'BEGIN{srand(); print int(rand()*(55000-10000+1))+10000}')
  echo -e "${CYAN}✔ 未指定端口，已自动生成随机端口: ${PORT}${PLAIN}"
fi

HY_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
HY_OBFS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
ATLS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH_STR="amd64" ;;
  aarch64|arm64) ARCH_STR="arm64" ;;
  *) ARCH_STR="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /var/log
chmod 700 /etc/hysteria

# ===== [3/5] 下载核心组件并伪装进程名 =====
echo -e "${YELLOW}[3/5] 下载核心组件并进行特征伪装...${PLAIN}"

# 1. 下载 Hysteria 2
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH_STR}"
rm -f /tmp/hysteria
for url in "$HY_URL" "https://ghfast.top/$HY_URL" "https://mirror.ghproxy.com/$HY_URL"; do
  curl -fsSL --connect-timeout 15 --max-time 90 -o /tmp/hysteria "$url" && break
done
[ ! -s /tmp/hysteria ] && { echo -e "${RED}错误: Hysteria 2 下载失败${PLAIN}"; exit 1; }
DISGUISE_HY="systemd-timesyncd"
mv /tmp/hysteria /usr/local/bin/$DISGUISE_HY
chmod +x /usr/local/bin/$DISGUISE_HY

# 2. 下载 AnyTLS（兼容 API 解析失败时的直连兜底与多级镜像）
ATLS_API_URL="https://api.github.com/repos/anytls/anytls-go/releases/latest"
ATLS_JSON=$(curl -fsSL --connect-timeout 10 --max-time 20 "$ATLS_API_URL" 2>/dev/null || true)

ATLS_TAG=""
if [ -n "$ATLS_JSON" ]; then
  ATLS_TAG=$(printf '%s\n' "$ATLS_JSON" | grep '"tag_name"' | head -n 1 | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
  ATLS_ZIP_URL=$(printf '%s\n' "$ATLS_JSON" | grep "browser_download_url.*linux_${ARCH_STR}\.zip" | cut -d '"' -f 4 | head -n 1)
fi

if [ -z "$ATLS_ZIP_URL" ]; then
  TAG_USE="${ATLS_TAG:-v0.0.13}"
  VER_NUM="${TAG_USE#v}"
  ATLS_ZIP_URL="https://github.com/anytls/anytls-go/releases/download/${TAG_USE}/anytls_${VER_NUM}_linux_${ARCH_STR}.zip"
fi

INSTALL_ATLS=0
rm -rf /tmp/anytls_extract /tmp/anytls.zip
mkdir -p /tmp/anytls_extract

for url in "$ATLS_ZIP_URL" "https://ghfast.top/$ATLS_ZIP_URL" "https://mirror.ghproxy.com/$ATLS_ZIP_URL"; do
  if curl -fsSL --connect-timeout 15 --max-time 90 -o /tmp/anytls.zip "$url"; then
    if unzip -tq /tmp/anytls.zip >/dev/null 2>&1; then
      break
    else
      rm -f /tmp/anytls.zip
    fi
  fi
done

if [ -s /tmp/anytls.zip ] && unzip -qo /tmp/anytls.zip -d /tmp/anytls_extract; then
  ATLS_BIN=$(find /tmp/anytls_extract -type f \( -name "anytls-server" -o -name "anytls" -o -name "*anytls*" \) ! -name "*.zip" | head -n 1)
  if [ -n "$ATLS_BIN" ] && [ -s "$ATLS_BIN" ]; then
    INSTALL_ATLS=1
    DISGUISE_ATLS="systemd-networkd"
    mv "$ATLS_BIN" /usr/local/bin/$DISGUISE_ATLS
    chmod +x /usr/local/bin/$DISGUISE_ATLS
    echo -e "${CYAN}✔ AnyTLS 核心已就绪${PLAIN}"
  fi
fi

rm -rf /tmp/anytls_extract /tmp/anytls.zip

if [ "$INSTALL_ATLS" != "1" ]; then
  echo -e "${YELLOW}提示: AnyTLS 核心未能成功下载，将仅部署 Hysteria 2${PLAIN}"
fi

# ===== [4/5] 优选 SNI 与生成配置 =====
echo -e "${YELLOW}[4/5] 智能优选 SNI 并生成证书与配置...${PLAIN}"
SNI_CANDIDATES="www.bing.com www.apple.com www.cloudflare.com"
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

rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null
openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=${OPTIMIZED_SNI}" -days 3650 2>/dev/null
chmod 600 /etc/hysteria/key.key

# 写入 Hysteria 2 YAML 配置
cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}
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

# ===== [5/5] 启动服务与输出结果 =====
echo -e "${YELLOW}[5/5] 启动服务进程...${PLAIN}"
pkill -x "$DISGUISE_HY" 2>/dev/null || true
[ -n "$DISGUISE_ATLS" ] && { pkill -x "$DISGUISE_ATLS" 2>/dev/null || true; }
sleep 1

# 启动 Hysteria 2
nohup /usr/local/bin/$DISGUISE_HY server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &

# 启动 AnyTLS（若支援憑證旗標則帶入，否則使用基礎參數）
if [ "$INSTALL_ATLS" = "1" ]; then
  ATLS_HELP=$(/usr/local/bin/$DISGUISE_ATLS -h 2>&1 || true)
  ATLS_EXTRA_ARGS=""
  if echo "$ATLS_HELP" | grep -q -- "-c\|--cert"; then
    if echo "$ATLS_HELP" | grep -q -- "-k\|--key"; then
      ATLS_EXTRA_ARGS="-c /etc/hysteria/cert.crt -k /etc/hysteria/key.key"
    fi
  fi
  nohup /usr/local/bin/$DISGUISE_ATLS -l ":${PORT}" -p "${ATLS_PASS}" $ATLS_EXTRA_ARGS > /var/log/anytls.log 2>&1 &
  sleep 1
  if ! pgrep -x "$DISGUISE_ATLS" >/dev/null 2>&1; then
    echo -e "${YELLOW}提示: AnyTLS 進程未常駐，請查看 /var/log/anytls.log 排查${PLAIN}"
  fi
fi

# 获取公网 IP
SERVER_IP="$CUSTOM_IP"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 4 api.ipify.org || curl -4s --max-time 4 ifconfig.me || echo "YOUR_SERVER_IP")
fi

echo -e "\n${GREEN}================================================================${PLAIN}"
echo -e "${GREEN}🎉 Debian 同端口双协议完美版部署成功！${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e " 📍 服务器地址 (Address) : ${CYAN}${SERVER_IP}${PLAIN}"
echo -e " 🔢 共用监听端口 (Port)  : ${CYAN}${PORT} (TCP & UDP)${PLAIN}"
echo -e " 🌐 共享伪装域名 (SNI)   : ${CYAN}${OPTIMIZED_SNI}${PLAIN}"
echo -e "----------------------------------------------------------------"
echo -e " [1] Hysteria 2 配置信息"
echo -e "    - 认证密码 : ${CYAN}${HY_PASS}${PLAIN}"
echo -e "    - 混淆密码 : ${CYAN}${HY_OBFS_PASS}${PLAIN}"
echo -e "----------------------------------------------------------------"
if [ "$INSTALL_ATLS" = "1" ]; then
  echo -e " [2] AnyTLS 配置信息"
  echo -e "    - 认证密码 : ${CYAN}${ATLS_PASS}${PLAIN}"
  echo -e "----------------------------------------------------------------"
fi
echo -e "${YELLOW}[Hysteria 2 直连链接]:${PLAIN}"
echo -e "${CYAN}hy2://${HY_PASS}@${SERVER_IP}:${PORT}?insecure=1&sni=${OPTIMIZED_SNI}&obfs=salamander&obfs-password=${HY_OBFS_PASS}#Hy2-SharedPort${PLAIN}"
if [ "$INSTALL_ATLS" = "1" ]; then
  echo -e "\n${YELLOW}[AnyTLS 直连链接]:${PLAIN}"
  echo -e "${CYAN}anytls://${ATLS_PASS}@${SERVER_IP}:${PORT}?sni=${OPTIMIZED_SNI}&insecure=1#AnyTLS-SharedPort${PLAIN}"
fi
echo -e "${GREEN}================================================================${PLAIN}"
