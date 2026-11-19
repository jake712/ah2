#!/bin/sh
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

CUSTOM_PORT=""
CUSTOM_IP=""
ENABLE_ARGO=0
ARGO_TOKEN=""

while getopts "p:i:ak:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    a) ENABLE_ARGO=1 ;;
    k) ARGO_TOKEN=$OPTARG; ENABLE_ARGO=1 ;;
    h)
      echo "用法: $0 [-p 端口] [-i 公网IP] [-a] [-k Token]"
      exit 0
      ;;
  esac
done

[ "$(id -u)" != "0" ] && { echo -e "${RED}请使用 root 运行${PLAIN}"; exit 1; }

if ! command -v apk >/dev/null 2>&1; then
  echo -e "${RED}错误: 未检测到 apk，此版本适用于 Alpine Linux${PLAIN}"
  exit 1
fi

echo -e "${YELLOW}[1/4] 安装 Alpine 依赖...${PLAIN}"
if ! grep -q "nameserver" /etc/resolv.conf 2>/dev/null; then
  printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
fi
apk update >/dev/null
apk add --no-cache curl openssl ca-certificates gawk iproute2 unzip procps >/dev/null

PORT="${CUSTOM_PORT:-$(awk 'BEGIN{srand(); print int(rand()*(55000-10000+1))+10000}')}"
HY_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
HY_OBFS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
ATLS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

case "$(uname -m)" in
  x86_64|amd64) ARCH_STR="amd64" ;;
  aarch64|arm64) ARCH_STR="arm64" ;;
  *) ARCH_STR="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /var/log
chmod 700 /etc/hysteria

echo -e "${YELLOW}[2/4] 下载核心组件...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH_STR}"
curl -fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" || curl -fsSL --max-time 30 -o /tmp/hysteria "https://ghfast.top/$HY_URL"
[ ! -s /tmp/hysteria ] && { echo -e "${RED}Hysteria 2 下载失败${PLAIN}"; exit 1; }
DISGUISE_HY="systemd-timesyncd"
mv /tmp/hysteria "/usr/local/bin/$DISGUISE_HY"
chmod +x "/usr/local/bin/$DISGUISE_HY"

ATLS_API_URL="https://api.github.com/repos/anytls/anytls-go/releases/latest"
ATLS_ZIP_URL=$(curl -s --max-time 10 "$ATLS_API_URL" | grep "browser_download_url.*linux_${ARCH_STR}\.zip" | cut -d '"' -f 4 | head -n 1)
INSTALL_ATLS=0
DISGUISE_ATLS="systemd-networkd"
if [ -n "$ATLS_ZIP_URL" ]; then
  if curl -fsSL --max-time 30 -o /tmp/anytls.zip "$ATLS_ZIP_URL" || curl -fsSL --max-time 30 -o /tmp/anytls.zip "https://ghfast.top/$ATLS_ZIP_URL"; then
    if [ -s /tmp/anytls.zip ]; then
      unzip -qo /tmp/anytls.zip -d /tmp/
      ATLS_BIN=$(find /tmp -maxdepth 1 -type f \( -name "anytls-server" -o -name "anytls" \) | head -n 1)
      if [ -n "$ATLS_BIN" ] && [ -s "$ATLS_BIN" ]; then
        INSTALL_ATLS=1
        mv "$ATLS_BIN" "/usr/local/bin/$DISGUISE_ATLS"
        chmod +x "/usr/local/bin/$DISGUISE_ATLS"
      fi
    fi
  fi
fi

INSTALL_ARGO=0
DISGUISE_ARGO="systemd-journald"
if [ "$ENABLE_ARGO" = "1" ]; then
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_STR}"
  if curl -fsSL --max-time 40 -o /tmp/cloudflared "$CF_URL" || curl -fsSL --max-time 40 -o /tmp/cloudflared "https://ghfast.top/$CF_URL"; then
    if [ -s /tmp/cloudflared ]; then
      INSTALL_ARGO=1
      mv /tmp/cloudflared "/usr/local/bin/$DISGUISE_ARGO"
      chmod +x "/usr/local/bin/$DISGUISE_ARGO"
    fi
  fi
fi

echo -e "${YELLOW}[3/4] 生成证书与配置...${PLAIN}"
OPTIMIZED_SNI="www.bing.com"
LOWEST_LATENCY=9999
for domain in www.bing.com www.apple.com www.cloudflare.com; do
  latency=$(curl -o /dev/null -s -w '%{time_connect}\n' --connect-timeout 2 -m 3 "https://$domain" 2>/dev/null || echo "999")
  if awk -v l="$latency" -v min="$LOWEST_LATENCY" 'BEGIN {exit !(l > 0 && l < min)}'; then
    LOWEST_LATENCY=$latency
    OPTIMIZED_SNI=$domain
  fi
done

openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null
openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=${OPTIMIZED_SNI}" -days 3650 2>/dev/null
chmod 600 /etc/hysteria/key.key

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

echo -e "${YELLOW}[4/4] 启动服务...${PLAIN}"
pkill -x "$DISGUISE_HY" 2>/dev/null || true
[ "$INSTALL_ATLS" = "1" ] && { pkill -x "$DISGUISE_ATLS" 2>/dev/null || true; }
[ "$INSTALL_ARGO" = "1" ] && { pkill -x "$DISGUISE_ARGO" 2>/dev/null || true; }
sleep 1

nohup "/usr/local/bin/$DISGUISE_HY" server -c /etc/hysteria/config.yaml >/var/log/hysteria.log 2>&1 &
[ "$INSTALL_ATLS" = "1" ] && nohup "/usr/local/bin/$DISGUISE_ATLS" -l ":${PORT}" -p "${ATLS_PASS}" >/var/log/anytls.log 2>&1 &

ARGO_DOMAIN=""
if [ "$INSTALL_ARGO" = "1" ]; then
  : > /var/log/argo.log
  if [ -n "$ARGO_TOKEN" ]; then
    nohup "/usr/local/bin/$DISGUISE_ARGO" tunnel --no-autoupdate run --token "$ARGO_TOKEN" >/var/log/argo.log 2>&1 &
    ARGO_DOMAIN="(由 Cloudflare Zero Trust 控制台绑定域名)"
  else
    nohup "/usr/local/bin/$DISGUISE_ARGO" tunnel --no-autoupdate --url "http://127.0.0.1:${PORT}" >/var/log/argo.log 2>&1 &
    for _ in $(seq 1 15); do
      sleep 1
      ARGO_DOMAIN=$(grep -Eo 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' /var/log/argo.log | head -n 1 | sed 's#https://##')
      [ -n "$ARGO_DOMAIN" ] && break
    done
  fi
fi

SERVER_IP="${CUSTOM_IP:-$(curl -4s --max-time 4 api.ipify.org || curl -4s --max-time 4 ifconfig.me || echo "YOUR_SERVER_IP")}"
echo -e "\n${GREEN}完成！IP: ${CYAN}${SERVER_IP}${PLAIN} | 端口: ${CYAN}${PORT}${PLAIN} | SNI: ${CYAN}${OPTIMIZED_SNI}${PLAIN}"
[ "$INSTALL_ARGO" = "1" ] && echo -e "Argo: ${CYAN}${ARGO_DOMAIN:-查看 /var/log/argo.log}${PLAIN}"
echo -e "Hy2: ${CYAN}hy2://${HY_PASS}@${SERVER_IP}:${PORT}?insecure=1&sni=${OPTIMIZED_SNI}&obfs=salamander&obfs-password=${HY_OBFS_PASS}#Hy2${PLAIN}"
[ "$INSTALL_ATLS" = "1" ] && echo -e "AnyTLS: ${CYAN}anytls://${ATLS_PASS}@${SERVER_IP}:${PORT}?sni=${OPTIMIZED_SNI}&insecure=1#AnyTLS${PLAIN}"
