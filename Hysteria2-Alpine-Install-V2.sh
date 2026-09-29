#!/bin/bash
# Hysteria 2 一鍵安裝腳本 for Alpine Linux V3.1 - 入口IP修復版
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'

while getopts "p:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 端口] [-w 密碼] [-i 入口IP]"; exit 0 ;;
  esac
done

CUSTOM_PORT=${CUSTOM_PORT:-${PORT:-}}
CUSTOM_PASSWORD=${CUSTOM_PASSWORD:-${PASSWORD:-}}
CUSTOM_IP=${CUSTOM_IP:-${SERVER_IP:-}}

if [ "$(id -u)" != "0" ]; then echo -e "${RED}請用 root 運行${PLAIN}"; exit 1; fi

echo -e "${YELLOW}[0/6] 正在優化 DNS...${PLAIN}"
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 223.5.5.5
EOF

get_arch() { case $(uname -m) in x86_64|amd64) echo "amd64";; aarch64|arm64) echo "arm64";; armv7l) echo "armv7";; *) echo "amd64";; esac; }
gen_password() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; }

if [ -z "$CUSTOM_PORT" ]; then
  while true; do
    read -p "請輸入 Hysteria 2 端口 (1-65535): " input_port
    if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then HY_PORT=$input_port; break;
    else echo -e "${RED}請輸入正確的端口！${PLAIN}"; fi
  done
else HY_PORT=$CUSTOM_PORT; fi

if [ -z "$CUSTOM_PASSWORD" ]; then HY_PASS=$(gen_password); echo -e "${YELLOW}已自動生成密碼: $HY_PASS${PLAIN}"; else HY_PASS=$CUSTOM_PASSWORD; fi

echo -e "${GREEN}=== 開始安裝 Hysteria 2 ===${PLAIN}"

echo -e "${YELLOW}[1/6] 安裝依賴...${PLAIN}"
apk update; for pkg in bash curl wget openssl tar iproute2 file procps; do apk add --no-cache $pkg || true; done
mkdir -p /usr/local/bin /etc/ssl/private /etc/hysteria /var/log

echo -e "${YELLOW}[2/6] 下載 Hysteria 2...${PLAIN}"
ARCH_TYPE=$(get_arch); DEST="/usr/local/bin/hysteria"
if [ "$ARCH_TYPE" = "arm64" ]; then BIN_NAME="hysteria-linux-arm64"; else BIN_NAME="hysteria-linux-amd64"; fi
BASE="https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
URLS=("${BASE}" "https://ghps.cc/${BASE}" "https://ghproxy.net/${BASE}" "https://ghfast.top/${BASE}" "https://github.moeyy.xyz/${BASE}")

download_success=0
for URL in "${URLS[@]}"; do
  echo -e " 嘗試: $URL"; rm -f /tmp/hy.download
  if curl -fL --connect-timeout 10 --max-time 120 -o /tmp/hy.download "$URL" 2>&1; then
    if head -c 200 /tmp/hy.download | grep -qi "<html"; then continue; fi
    if ! head -c 4 /tmp/hy.download | grep -q $'\x7fELF'; then continue; fi
    mv /tmp/hy.download "$DEST"; chmod +x "$DEST"; download_success=1; echo -e "${GREEN} -> 成功${PLAIN}"; break
  fi
done
[ "$download_success" -ne
