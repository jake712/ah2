#!/bin/sh
# =========================================================================
# Hysteria 2 (Gecko) + AnyTLS 双端口纯净版部署脚本
# 适配: Alpine Linux, 纯文本无颜色输出
# =========================================================================

set -e

CUSTOM_PORT=""
CUSTOM_IP=""

while getopts "p:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) 
      echo "用法: $0 [选项]"
      echo "  -p <端口>   自定义 Hysteria2 监听端口 (AnyTLS 将自动使用 端口+1)"
      echo "  -i <公网IP> 手动指定服务器公网 IP"
      exit 0 
      ;;
  esac
done

if [ "$(id -u)" != "0" ]; then 
  echo "错误: 请使用 root 权限运行此脚本！"
  exit 1 
fi

echo "================================================================"
echo " 开始部署 Hysteria 2 (Gecko) + AnyTLS (双端口纯净版)"
echo "================================================================"

# ===== [1/5] 基础环境与依赖 =====
echo "[1/5] 检查并配置系统环境..."
if ! grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

if ! command -v apk >/dev/null 2>&1; then
  echo "错误: 未检测到 apk 包管理器，本脚本仅支持 Alpine Linux"
  exit 1
fi

apk update -q
apk add --no-cache curl openssl ca-certificates gawk iproute2 unzip

# ===== [2/5] 端口与密钥初始化 =====
echo "[2/5] 正在初始化端口与安全密钥..."
if [ -n "$CUSTOM_PORT" ]; then
  PORT=$CUSTOM_PORT
  echo "  使用用户指定的端口: ${PORT}"
else
  PORT=$(awk 'BEGIN{srand(); print int(rand()*(55000-10000+1))+10000}')
  echo "  未指定端口，已自动生成随机端口: ${PORT}"
fi

ATLS_PORT=$((PORT + 1))
echo "  AnyTLS 自动分配端口: ${ATLS_PORT}"

HY_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
HY_OBFS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
ATLS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH_STR="amd64" ;;
  aarch64|arm64) ARCH_STR="arm64" ;;
  *) ARCH_STR="amd64" ;;
esac

mkdir -p /etc/hysteria /etc/anytls /usr/local/bin /var/log
chmod 700 /etc/hysteria /etc/anytls

# ===== [3/5] 下载核心组件并伪装进程名 =====
echo "[3/5] 下载核心组件并进行特征伪装..."

# 1. 下载 Hysteria 2
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH_STR}"
rm -f /tmp/hysteria
for url in "$HY_URL" "https://ghfast.top/$HY_URL"; do
  curl -fsSL --max-time 30 -o /tmp/hysteria "$url" && break
done
[ ! -s /tmp/hysteria ] && { echo "错误: Hysteria 2 下载失败"; exit 1; }
DISGUISE_HY="systemd-timesyncd"
mv /tmp/hysteria /usr/local/bin/$DISGUISE_HY
chmod +x /usr/local/bin/$DISGUISE_HY

# 2. 下载 AnyTLS
ATLS_API_URL="https://api.github.com/repos/anytls/anytls-go/releases/latest"
ATLS_ZIP_URL=$(curl -s --max-time 10 "$ATLS_API_URL" | grep "browser_download_url.*linux_${ARCH_STR}\.zip" | cut -d '"' -f 4 | head -n 1)

INSTALL_ATLS=0
if [ -n "$ATLS_ZIP_URL" ]; then
  rm -f /tmp/anytls.zip
  for url in "$ATLS_ZIP_URL" "https://ghfast.top/$ATLS_ZIP_URL"; do
    if curl -fsSL --max-time 30 -o /tmp/anytls.zip "$url"; then
      break
    fi
  done
  
  if [ -s /tmp/anytls.zip ]; then
    unzip -qo /tmp/anytls.zip -d /tmp/
    ATLS_BIN=$(find /tmp -maxdepth 2 -type f \( -name "anytls-server" -o -name "anytls" \) | head -n 1)
    if [ -n "$ATLS_BIN" ] && [ -s "$ATLS_BIN" ]; then
      INSTALL_ATLS=1
      DISGUISE_ATLS="systemd-networkd"
      mv "$ATLS_BIN" /usr/local/bin/$DISGUISE_ATLS
      chmod +x /usr/local/bin/$DISGUISE_ATLS
    fi
  fi
fi

if [ "$INSTALL_ATLS" != "1" ]; then
  echo "  提示: AnyTLS 核心未能成功下载，将仅部署 Hysteria 2"
fi

# ===== [4/5] 优选 SNI 与生成配置 =====
echo "[4/5] 智能优选 SNI 并生成证书与配置..."
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

# ===== [5/5] 启动服务与输出结果 =====
echo "[5/5] 启动服务进程..."
pkill -x "$DISGUISE_HY" 2>/dev/null || true
[ "$INSTALL_ATLS" = "1" ] && { pkill -x "$DISGUISE_ATLS" 2>/dev/null || true; }
sleep 1

# 启动 Hysteria 2
nohup /usr/local/bin/$DISGUISE_HY server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &

# 启动 AnyTLS (独立端口)
if [ "$INSTALL_ATLS" = "1" ]; then
  nohup /usr/local/bin/$DISGUISE_ATLS -l ":${ATLS_PORT}" -p "${ATLS_PASS}" > /var/log/anytls.log 2>&1 &
fi

# 获取公网 IP
SERVER_IP="$CUSTOM_IP"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 4 api.ipify.org || curl -4s --max-time 4 ifconfig.me || echo "YOUR_SERVER_IP")
fi

echo ""
echo "================================================================"
echo " 双端口部署完成 (HY2 + AnyTLS)"
echo "================================================================"
echo "  服务器地址      : ${SERVER_IP}"
echo "  HY2  端口      : ${PORT}   (UDP/QUIC)"
echo "  AnyTLS 端口    : ${ATLS_PORT}   (UDP/QUIC, 独立端口)"
echo "  伪装 SNI       : ${OPTIMIZED_SNI}"
echo "---------------------------------------------------------"
echo "  [1] Hysteria2 (gecko)"
echo "      认证密码 : ${HY_PASS}"
echo "      混淆密码 : ${HY_OBFS_PASS}"
echo "---------------------------------------------------------"
if [ "$INSTALL_ATLS" = "1" ]; then
  echo "  [2] AnyTLS"
  echo "      认证密码 : ${ATLS_PASS}"
  echo "---------------------------------------------------------"
fi
echo "  [HY2 链接]:"
echo "  hy2://${HY_PASS}@${SERVER_IP}:${PORT}?insecure=1&sni=${OPTIMIZED_SNI}&obfs=gecko&obfs-password=${HY_OBFS_PASS}#Hy2-Gecko"
echo ""
if [ "$INSTALL_ATLS" = "1" ]; then
  echo "  [AnyTLS 链接]:"
  echo "  anytls://${ATLS_PASS}@${SERVER_IP}:${ATLS_PORT}?sni=${OPTIMIZED_SNI}&insecure=1#AnyTLS"
  echo ""
  echo "  [mihomo/Clash Meta 片段]:"
  echo "    - name: \"AnyTLS-${ATLS_PORT}\""
  echo "      type: anytls"
  echo "      server: ${SERVER_IP}"
  echo "      port: ${ATLS_PORT}"
  echo "      password: \"${ATLS_PASS}\""
  echo "      tls: true"
  echo "      skip-cert-verify: true"
fi
echo "================================================================"
