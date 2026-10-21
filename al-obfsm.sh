#!/bin/sh
# Hysteria 2 Alpine V1.1 - 多端口跳动修復版
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

while getopts "p:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 端口范围，如 20000-30000] [-w 认证密码] [-i 公网IP]"; exit 0 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

echo -e "${GREEN}=== Hysteria2 Alpine 多端口跳动防封锁版 ===${PLAIN}"

# ===== [1/5] 基础依赖 =====
echo -e "${YELLOW}[1/5] 检查并安装 Alpine 依赖...${PLAIN}"
if ! command -v apk >/dev/null 2>&1; then
  echo -e "${RED}未检测到 apk，不是 Alpine Linux 系统${PLAIN}"; exit 1
fi

apk update -q
apk add --no-cache curl openssl bind-tools iproute2 ca-certificates iptables

# ===== [2/5] 参数初始化 =====
echo -e "${YELLOW}[2/5] 初始化参数...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-20000-30000}

case "$HY_PORT" in
  *-*)
    BASE_PORT=$(echo "$HY_PORT" | cut -d'-' -f1)
    ;;
  *)
    BASE_PORT="$HY_PORT"
    ;;
esac

# 生成密码
HY_OBFS_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
if [ -n "$CUSTOM_PASSWORD" ]; then
  HY_PASS="$CUSTOM_PASSWORD"
else
  HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  *) HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /var/log
chmod 700 /etc/hysteria

# ===== [3/5] 下载 Hysteria2 =====
echo -e "${YELLOW}[3/5] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
curl -4fsSL --max-time 30 -o /usr/local/bin/hysteria "$HY_URL" || \
curl -4fsSL --max-time 30 -o /usr/local/bin/hysteria "https://ghfast.top/$HY_URL"

if [ ! -s /usr/local/bin/hysteria ]; then echo -e "${RED}下载失败${PLAIN}"; exit 1; fi
chmod +x /usr/local/bin/hysteria

# ===== [4/5] 生成证书与配置 =====
echo -e "${YELLOW}[4/5] 生成配置与证书...${PLAIN}"
RANDOM_SNI="bing.com"

rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null
openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=${RANDOM_SNI}" -days 3650 2>/dev/null
chmod 600 /etc/hysteria/key.key

# 使用标准空格写入 YAML (避免 YAML 解析崩溃)
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
    url: https://${RANDOM_SNI}
    rewriteHost: true

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
EOF

# ===== [5/5] 启动服务 =====
echo -e "${YELLOW}[5/5] 启动服务...${PLAIN}"
pkill -f "hysteria.*config.yaml" || true
sleep 1
nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &

SERVER_IP=$CUSTOM_IP
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 5 api.ipify.org || curl -4s --max-time 5 ifconfig.me || echo "你的服务器IP")
fi

echo -e "\n${GREEN}================================================"
echo -e "Hysteria 2 部署成功！"
echo -e "================================================${PLAIN}"
echo -e "${CYAN}[标准 Hysteria2 节点链接]:${PLAIN}"
echo -e "hy2://${HY_PASS}@${SERVER_IP}:${BASE_PORT}?mport=${HY_PORT}&insecure=1&sni=${RANDOM_SNI}&obfs=salamander&obfs-password=${HY_OBFS_PASS}"
echo -e "================================================${PLAIN}"
