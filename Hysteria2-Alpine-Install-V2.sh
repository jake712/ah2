#!/bin/bash
# Hysteria 2 一鍵安裝腳本 for Alpine Linux V3.0 - 修復版
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

# DNS
echo -e "${YELLOW}[0/6] 正在優化 DNS...${PLAIN}"
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 223.5.5.5
EOF

get_arch() {
  case $(uname -m) in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *) echo "amd64" ;;
  esac
}
gen_password() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; }

if [ -z "$CUSTOM_PORT" ]; then
  while true; do
    read -p "請輸入 Hysteria 2 端口 (1-65535): " input_port
    if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then HY_PORT=$input_port; break;
    else echo -e "${RED}請輸入正確的端口數字 (1-65535)！${PLAIN}"; fi
  done
else HY_PORT=$CUSTOM_PORT; fi

if [ -z "$CUSTOM_PASSWORD" ]; then HY_PASS=$(gen_password); echo -e "${YELLOW}未指定密碼，已自動生成: $HY_PASS${PLAIN}"; else HY_PASS=$CUSTOM_PASSWORD; fi

echo -e "${GREEN}=== 開始安裝 Hysteria 2 ===${PLAIN}"
echo -e "端口: $HY_PORT 密碼: $HY_PASS"

echo -e "${YELLOW}[1/6] 安裝依賴...${PLAIN}"
apk update
for pkg in bash curl wget openssl tar iproute2 file; do apk add --no-cache $pkg || true; done
mkdir -p /usr/local/bin /etc/ssl/private /etc/hysteria /var/log

# === 核心修復：下載邏輯 ===
echo -e "${YELLOW}[2/6] 下載 Hysteria 2 (修復版)...${PLAIN}"
ARCH_TYPE=$(get_arch)
DEST="/usr/local/bin/hysteria"

if [ "$ARCH_TYPE" = "arm64" ]; then BIN_NAME="hysteria-linux-arm64"; else BIN_NAME="hysteria-linux-amd64"; fi
BASE="https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"

# 這裡才是真正的完整 URL
URLS=(
  "${BASE}"
  "https://ghps.cc/${BASE}"
  "https://ghproxy.net/${BASE}"
  "https://ghfast.top/${BASE}"
  "https://github.moeyy.xyz/${BASE}"
  "https://fastgit.ogr.kr/https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
)

download_success=0
for URL in "${URLS[@]}"; do
  echo -e " 嘗試: $URL"
  rm -f "$DEST" /tmp/hy.download
  if curl -fL --connect-timeout 10 --max-time 120 -o /tmp/hy.download "$URL" 2>&1; then
    if head -c 200 /tmp/hy.download | grep -qi "<html\|<head"; then echo "  -> 返回 HTML，跳過"; continue; fi
    if ! head -c 4 /tmp/hy.download | grep -q $'\x7fELF'; then echo "  -> 非 ELF 二進制文件，跳過"; continue; fi
    SIZE=$(wc -c < /tmp/hy.download)
    if [ "$SIZE" -lt 5000000 ]; then echo "  -> 文件太小 ($SIZE bytes)，可能不完整，跳過"; continue; fi
    mv /tmp/hy.download "$DEST"; chmod +x "$DEST"; download_success=1
    echo -e "${GREEN} -> [成功] 下載完成 ($SIZE bytes) ${PLAIN}"; break
  else
    echo -e "${RED} -> 失敗，切換下一個鏡像...${PLAIN}"
  fi
done

if [ "$download_success" -ne 1 ]; then echo -e "${RED}錯誤：所有鏡像下載失敗！請檢查伺服器能否連上 GitHub。${PLAIN}"; exit 1; fi
"$DEST" version

# 3. 證書
echo -e "${YELLOW}[3/6] 生成 TLS 證書...${PLAIN}"
openssl ecparam -genkey -name prime256v1 -noout -out /etc/ssl/private/bing.key
openssl req -new -x509 -nodes -key /etc/ssl/private/bing.key -out /etc/ssl/private/bing.crt -days 3650 -subj "/CN=bing.com"
chmod 600 /etc/ssl/private/bing.key; chmod 644 /etc/ssl/private/bing.crt

# 4. 配置 (跟你原來一樣)
echo -e "${YELLOW}[4/6] 生成配置文件...${PLAIN}"
cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}
tls:
  cert: /etc/ssl/private/bing.crt
  key: /etc/ssl/private/bing.key
auth:
  type: password
  password: ${HY_PASS}
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF

# 5. 服務
cat > /etc/init.d/hysteria <<'SERVICE_EOF'
#!/sbin/openrc-run
name="Hysteria 2 Service"
description="Hysteria 2 Proxy Server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
depend() { need net; after firewall; }
start_pre() { checkpath --directory --mode 0755 /run/hysteria; checkpath --file --mode 0644 /var/log/hysteria.log; }
SERVICE_EOF
chmod +x /etc/init.d/hysteria; rc-update add hysteria default

# 6. 啟動
echo -e "${YELLOW}[6/6] 啟動服務...${PLAIN}"
rc-service hysteria restart || rc-service hysteria start; sleep 2
if ! rc-service hysteria status >/dev/null 2>&1; then echo -e "${RED}服務啟動失敗！${PLAIN}"; cat /var/log/hysteria.log; exit 1; fi

get_public_ip() {
  for api in "https://ifconfig.me" "https://ipinfo.io/ip" "https://icanhazip.com"; do
    ip=$(curl -4 -s --max-time 5 "$api" | tr -d ' \r\n' | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -n1)
    [ -n "$ip" ] && echo "$ip" && return
  done; echo ""
}
if [ -n "$CUSTOM_IP" ]; then SERVER_IP="$CUSTOM_IP"
else
  SERVER_IP=$(get_public_ip)
  [ -z "$SERVER_IP" ] && SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
  [ -z "$SERVER_IP" ] && SERVER_IP="YOUR_SERVER_IP"
fi

echo ""; echo -e "${GREEN}========== 安裝完成 ==========${PLAIN}"
echo -e "端口: ${GREEN}${HY_PORT}/udp${PLAIN} 密碼: ${GREEN}${HY_PASS}${PLAIN}"
echo "server: ${SERVER_IP}:${HY_PORT}"; echo "auth: ${HY_PASS}"; echo "tls:"; echo "  sni: bing.com"; echo "  insecure: true"; echo ""
echo -e "URI: ${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Alpine-Hy2${PLAIN}"
