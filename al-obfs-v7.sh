#!/bin/sh
# =========================================================================
# VLESS (Reality) + Hysteria 2 (Gecko) Alpine 同端口终极完美版部署脚本
# 适配: Alpine Linux 3.20/3.21/3.22+, Podman / Docker 容器及原生系统
# 协议分流: TCP 端口给 VLESS-Reality (Xray), UDP 端口给 Hysteria2
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

echo -e "${GREEN}=== 开始部署 VLESS (Reality) + Hysteria 2 (Gecko) 同端口双协议完美版 ===${PLAIN}"

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
  echo -e "${CYAN}[OK] 使用用户指定的端口: ${PORT}${PLAIN}"
else
  PORT=$(awk 'BEGIN{srand(); print int(rand()*(55000-10000+1))+10000}')
  echo -e "${CYAN}[OK] 未指定端口，已自动生成随机端口: ${PORT}${PLAIN}"
fi

HY_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
HY_OBFS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
VL_UUID=$(openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
VL_SID=$(openssl rand -hex 4)

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH_STR="amd64"; XRAY_ARCH="64" ;;
  aarch64|arm64) ARCH_STR="arm64"; XRAY_ARCH="arm64-v8a" ;;
  *) ARCH_STR="amd64"; XRAY_ARCH="64" ;;
esac

mkdir -p /etc/hysteria /etc/xray /usr/local/bin /var/log
chmod 700 /etc/hysteria /etc/xray

# ===== [3/5] 下载核心组件并伪装进程名 =====
echo -e "${YELLOW}[3/5] 下载核心组件并进行特征伪装...${PLAIN}"

# 1. 下载 Hysteria 2
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH_STR}"
rm -f /tmp/hysteria
for url in "$HY_URL" "https://ghfast.top/$HY_URL"; do
  curl -fsSL --max-time 30 -o /tmp/hysteria "$url" && break
done
[ ! -s /tmp/hysteria ] && { echo -e "${RED}错误: Hysteria 2 下载失败${PLAIN}"; exit 1; }
DISGUISE_HY="systemd-timesyncd"
mv /tmp/hysteria /usr/local/bin/$DISGUISE_HY
chmod +x /usr/local/bin/$DISGUISE_HY

# 2. 下载 Xray (用于 VLESS + Reality)
XRAY_ZIP="/tmp/xray.zip"
XRAY_XTDIR="/tmp/xray_extract"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"
INSTALL_XRAY=0
rm -rf "$XRAY_ZIP" "$XRAY_XTDIR"
for url in "$XRAY_URL" "https://ghfast.top/$XRAY_URL"; do
  if curl -fsSL --max-time 40 -o "$XRAY_ZIP" "$url"; then
    break
  fi
done
if [ -s "$XRAY_ZIP" ]; then
  mkdir -p "$XRAY_XTDIR"
  unzip -qo "$XRAY_ZIP" -d "$XRAY_XTDIR"
  XRAY_BIN=$(find "$XRAY_XTDIR" -maxdepth 1 -type f -name "xray" | head -n 1)
  if [ -n "$XRAY_BIN" ] && [ -s "$XRAY_BIN" ]; then
    INSTALL_XRAY=1
    DISGUISE_XRAY="systemd-resolved"
    mv "$XRAY_BIN" /usr/local/bin/$DISGUISE_XRAY
    chmod +x /usr/local/bin/$DISGUISE_XRAY
    XRAY_PATH="/usr/local/bin/$DISGUISE_XRAY"
  fi
fi

if [ "$INSTALL_XRAY" != "1" ]; then
  echo -e "${RED}错误: Xray 核心下载失败，无法部署 VLESS-Reality${PLAIN}"
  exit 1
fi

# 3. 生成 Reality 密钥对 (x25519)
echo -e "${YELLOW}正在生成 Reality x25519 密钥对...${PLAIN}"
KEY_OUT=$($XRAY_PATH x25519 2>/dev/null || echo "")
VL_PRIV=$(echo "$KEY_OUT" | grep -i "Private" | awk '{print $2}')
VL_PUB=$(echo "$KEY_OUT" | grep -iE "Public|Password" | awk '{print $2}')
[ -z "$VL_PRIV" ] || [ -z "$VL_PUB" ] && { echo -e "${RED}错误: Reality 密钥对生成失败${PLAIN}"; exit 1; }

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

# Hysteria2 自签证书
rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null
openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=${OPTIMIZED_SNI}" -days 3650 2>/dev/null
chmod 600 /etc/hysteria/key.key

# 写入 Hysteria 2 YAML 配置 (Gecko 混淆)
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

# 写入 Xray JSON 配置 (VLESS + Reality)
cat > /etc/xray/config.json <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${VL_UUID}", "flow": "xtls-rprx-vision" }
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
          "serverNames": ["${OPTIMIZED_SNI}"],
          "privateKey": "${VL_PRIV}",
          "shortIds": ["${VL_SID}"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
chmod 600 /etc/xray/config.json

# ===== [5/5] 启动服务与输出结果 =====
echo -e "${YELLOW}[5/5] 启动服务进程...${PLAIN}"
pkill -x "$DISGUISE_HY" 2>/dev/null || true
pkill -x "$DISGUISE_XRAY" 2>/dev/null || true
sleep 1

# 启动 VLESS (Reality) —— 占用 TCP 端口
nohup $XRAY_PATH -c /etc/xray/config.json > /var/log/xray.log 2>&1 &
sleep 1

# 启动 Hysteria 2 —— 占用 UDP 端口 (其 TCP 绑定让位于 VLESS, 不影响 UDP 代理)
nohup /usr/local/bin/$DISGUISE_HY server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &

# 获取公网 IP
SERVER_IP="$CUSTOM_IP"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 4 api.ipify.org || curl -4s --max-time 4 ifconfig.me || echo "YOUR_SERVER_IP")
fi

echo -e "\n${GREEN}================================================================${PLAIN}"
echo -e "${GREEN}[SUCCESS] 同端口双协议 (VLESS-Reality + Hysteria2-Gecko) 部署成功！${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e " [Server] 服务器地址 (Address) : ${CYAN}${SERVER_IP}${PLAIN}"
echo -e " [Port]   共用监听端口 (Port)  : ${CYAN}${PORT}${PLAIN}  (TCP=VLESS, UDP=Hysteria2)"
echo -e " [SNI]    共享伪装域名 (SNI)   : ${CYAN}${OPTIMIZED_SNI}${PLAIN}"
echo -e "----------------------------------------------------------------"
echo -e " [1] VLESS + Reality 配置信息 (推荐 / Karing 完美支持)"
echo -e "   - UUID      : ${CYAN}${VL_UUID}${PLAIN}"
echo -e "   - Flow      : ${CYAN}xtls-rprx-vision${PLAIN}"
echo -e "   - Reality公钥(PublicKey/pbk) : ${CYAN}${VL_PUB}${PLAIN}"
echo -e "   - ShortId(sid) : ${CYAN}${VL_SID}${PLAIN}"
echo -e "   - Fingerprint  : ${CYAN}chrome${PLAIN}"
echo -e "----------------------------------------------------------------"
echo -e " [2] Hysteria 2 配置信息 (Gecko)"
echo -e "   - 认证密码 : ${CYAN}${HY_PASS}${PLAIN}"
echo -e "   - 混淆类型 : ${CYAN}gecko${PLAIN}"
echo -e "   - 混淆密码 : ${CYAN}${HY_OBFS_PASS}${PLAIN}"
echo -e "----------------------------------------------------------------"
echo -e "${YELLOW}[VLESS + Reality 直连链接]:${PLAIN}"
echo -e "${CYAN}vless://${VL_UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${OPTIMIZED_SNI}&fp=chrome&pbk=${VL_PUB}&sid=${VL_SID}&type=tcp#VLESS-Reality-SharedPort${PLAIN}"
echo -e "\n${YELLOW}[Hysteria 2 直连链接]:${PLAIN}"
echo -e "${CYAN}hy2://${HY_PASS}@${SERVER_IP}:${PORT}?insecure=1&sni=${OPTIMIZED_SNI}&obfs=gecko&obfs-password=${HY_OBFS_PASS}#Hy2-Gecko-SharedPort${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
