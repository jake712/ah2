#!/bin/sh
# =========================================================================
# Hysteria 2 (Gecko) + VLESS (XTLS-Reality) Alpine 同端口部署脚本
# 适配: Alpine Linux 3.20/3.21/3.22+, Podman / Docker 容器及原生系统
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

echo -e "${GREEN}=== 开始部署 Hysteria 2 (Gecko) + VLESS-Reality (同端口双协议) ===${PLAIN}"

# ===== [1/5] 基础环境与依赖 =====
echo -e "${YELLOW}[1/5] 检查并配置系统环境...${PLAIN}"
if ! grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
  fi
fi

if ! command -v apk >/dev/null 2>&1; then
  echo -e "${RED}错误: 未检测到 apk 包管理器，本脚本仅支持 Alpine Linux${PLAIN}"
  exit 1
fi

apk update -q
apk add --no-cache curl openssl ca-certificates gawk iproute2 unzip

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
VLESS_SHORT_ID=$(openssl rand -hex 4)

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH_STR="64" ; HY_ARCH="amd64" ;;
  aarch64|arm64) ARCH_STR="arm64-v8a" ; HY_ARCH="arm64" ;;
  *) ARCH_STR="64" ; HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /etc/xray /usr/local/bin /var/log
chmod 700 /etc/hysteria /etc/xray

# ===== [3/5] 下载核心组件并伪装进程名 =====
echo -e "${YELLOW}[3/5] 下载核心组件并进行特征伪装...${PLAIN}"

# 1. 下载 Hysteria 2
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
for url in "$HY_URL" "https://ghfast.top/$HY_URL"; do
  curl -fsSL --max-time 30 -o /tmp/hysteria "$url" && break
done
[ ! -s /tmp/hysteria ] && { echo -e "${RED}错误: Hysteria 2 下载失败${PLAIN}"; exit 1; }
DISGUISE_HY="systemd-timesyncd"
mv /tmp/hysteria /usr/local/bin/$DISGUISE_HY
chmod +x /usr/local/bin/$DISGUISE_HY

# 2. 下载 Xray-core (用于 VLESS + XTLS-Reality)
XRAY_ZIP_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_STR}.zip"
INSTALL_VLESS=0
rm -rf /tmp/xray_extract /tmp/xray.zip
mkdir -p /tmp/xray_extract

for url in "$XRAY_ZIP_URL" "https://ghfast.top/$XRAY_ZIP_URL"; do
  if curl -fsSL --max-time 40 -o /tmp/xray.zip "$url"; then
    break
  fi
done

if [ -s /tmp/xray.zip ]; then
  unzip -qo /tmp/xray.zip -d /tmp/xray_extract
  if [ -s /tmp/xray_extract/xray ]; then
    INSTALL_VLESS=1
    DISGUISE_XRAY="systemd-networkd"
    mv /tmp/xray_extract/xray /usr/local/bin/$DISGUISE_XRAY
    chmod +x /usr/local/bin/$DISGUISE_XRAY
  fi
fi
rm -rf /tmp/xray_extract /tmp/xray.zip

if [ "$INSTALL_VLESS" != "1" ]; then
  echo -e "${YELLOW}提示: Xray 核心未能成功下载，将仅部署 Hysteria 2${PLAIN}"
fi

# ===== [4/5] 优选 SNI 与生成配置 =====
echo -e "${YELLOW}[4/5] 智能优选 SNI 并生成证书与配置...${PLAIN}"
SNI_CANDIDATES="www.amd.com www.apple.com www.microsoft.com www.samsung.com www.sony.com www.oracle.com"
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

# Hysteria 2 自签证书与配置
rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null
openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=${OPTIMIZED_SNI}" -days 3650 2>/dev/null
chmod 600 /etc/hysteria/key.key

cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}
auth:
  type: password
  password: ${HY_PASS}
obfs:
  type: gecko
  gecko:
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

# VLESS-Reality 配置
if [ "$INSTALL_VLESS" = "1" ]; then
  VLESS_UUID=$(/usr/local/bin/$DISGUISE_XRAY uuid)
  X25519_OUT=$(/usr/local/bin/$DISGUISE_XRAY x25519)
  # 兼容不同版本 xray x25519 输出格式 (PrivateKey / Private key)
  VLESS_PRIV_KEY=$(echo "$X25519_OUT" | awk -F': ' '/[Pp]rivate ?[Kk]ey/ {print $2; exit}')
  VLESS_PUB_KEY=$(echo "$X25519_OUT" | awk -F': ' '/[Pp]ublic ?[Kk]ey/ {print $2; exit}')

  if [ -z "$VLESS_UUID" ] || [ -z "$VLESS_PRIV_KEY" ] || [ -z "$VLESS_PUB_KEY" ]; then
    echo -e "${YELLOW}警告: VLESS 密钥生成异常，跳过 VLESS 部署${PLAIN}"
    INSTALL_VLESS=0
  else
    cat > /etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${OPTIMIZED_SNI}:443",
          "xver": 0,
          "serverNames": [
            "${OPTIMIZED_SNI}"
          ],
          "privateKey": "${VLESS_PRIV_KEY}",
          "shortIds": [
            "${VLESS_SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
  fi
fi

# ===== [5/5] 启动服务与输出结果 =====
echo -e "${YELLOW}[5/5] 启动服务进程...${PLAIN}"
pkill -x "$DISGUISE_HY" 2>/dev/null || true
[ "$INSTALL_VLESS" = "1" ] && { pkill -x "$DISGUISE_XRAY" 2>/dev/null || true; }
sleep 1

# 启动 Hysteria 2 (UDP)
nohup /usr/local/bin/$DISGUISE_HY server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &

# 启动 Xray VLESS-Reality (TCP)
if [ "$INSTALL_VLESS" = "1" ]; then
  nohup /usr/local/bin/$DISGUISE_XRAY run -c /etc/xray/config.json > /var/log/xray.log 2>&1 &
fi

# 获取公网 IP
SERVER_IP="$CUSTOM_IP"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 4 api.ipify.org || curl -4s --max-time 4 ifconfig.me || echo "YOUR_SERVER_IP")
fi

echo -e "\n${GREEN}================================================================${PLAIN}"
echo -e "${GREEN}🎉 同端口双协议 (VLESS-Reality + Hy2 Gecko) 部署成功！${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e " 📍 服务器地址 (Address) : ${CYAN}${SERVER_IP}${PLAIN}"
echo -e " 🔢 共用监听端口 (Port)  : ${CYAN}${PORT} (TCP: VLESS / UDP: Hy2)${PLAIN}"
echo -e " 🌐 共享伪装域名 (SNI)   : ${CYAN}${OPTIMIZED_SNI}${PLAIN}"
echo -e "----------------------------------------------------------------"
echo -e " [1] Hysteria 2 配置信息 (Gecko)"
echo -e "   - 认证密码 : ${CYAN}${HY_PASS}${PLAIN}"
echo -e "   - 混淆类型 : ${CYAN}gecko${PLAIN}"
echo -e "   - 混淆密码 : ${CYAN}${HY_OBFS_PASS}${PLAIN}"
echo -e "----------------------------------------------------------------"
if [ "$INSTALL_VLESS" = "1" ]; then
  echo -e " [2] VLESS-Reality 配置信息"
  echo -e "   - UUID       : ${CYAN}${VLESS_UUID}${PLAIN}"
  echo -e "   - 流控 (Flow): ${CYAN}xtls-rprx-vision${PLAIN}"
  echo -e "   - PublicKey  : ${CYAN}${VLESS_PUB_KEY}${PLAIN}"
  echo -e "   - ShortId    : ${CYAN}${VLESS_SHORT_ID}${PLAIN}"
  echo -e "----------------------------------------------------------------"
fi
echo -e "${YELLOW}[Hysteria 2 直连链接]:${PLAIN}"
echo -e "${CYAN}hy2://${HY_PASS}@${SERVER_IP}:${PORT}?insecure=1&sni=${OPTIMIZED_SNI}&obfs=gecko&obfs-password=${HY_OBFS_PASS}#Hy2-Gecko-SharedPort${PLAIN}"
if [ "$INSTALL_VLESS" = "1" ]; then
  echo -e "\n${YELLOW}[VLESS-Reality 直连链接]:${PLAIN}"
  echo -e "${CYAN}vless://${VLESS_UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${OPTIMIZED_SNI}&fp=chrome&pbk=${VLESS_PUB_KEY}&sid=${VLESS_SHORT_ID}&type=tcp#VLESS-Reality-SharedPort${PLAIN}"
fi
echo -e "${GREEN}================================================================${PLAIN}"
