#!/bin/bash
# Hysteria 2 一鍵安裝腳本 for Alpine Linux V2.6 - 低記憶體優化版
# 用法: ./hysteria2-alpine-install.sh -p [端口] -w "你的密碼" -i "你的入口IP"
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'

while getopts "p:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 端口] [-w 密碼] [-i 入口IP]"; echo "  -p 端口  指定服務監聽端口 (必填)"; echo "  -w 密碼  指定固定密碼 (選填，不填則自動生成隨機密碼)"; echo "  -i IP    手動指定對外展示的服務器IP (入口IP)"; exit 0 ;;
  esac
done

CUSTOM_PORT=${CUSTOM_PORT:-${PORT:-}}
CUSTOM_PASSWORD=${CUSTOM_PASSWORD:-${PASSWORD:-}}
CUSTOM_IP=${CUSTOM_IP:-${SERVER_IP:-}}

if [ "$(id -u)" != "0" ]; then echo -e "${RED}請用 root 運行${PLAIN}"; exit 1; fi

# 低記憶體預警檢查 (Swap 檢查)
TOTAL_SWAP=$(free -m | awk '/Swap/ {print $2}')
if [ "${TOTAL_SWAP:-0}" -eq 0 ]; then
  echo -e "${YELLOW}[提示] 檢測到系統未啟用 Swap 虛擬記憶體。如果是極低記憶體(如128MB/256MB)環境，接下來可能還會被系統 Killed。${PLAIN}"
fi

get_arch() {
  ARCH=$(uname -m)
  case $ARCH in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *) echo "amd64" ;;
  esac
}
gen_password() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; }

# 端口處理：強制要求輸入
if [ -z "$CUSTOM_PORT" ]; then
  while true; do
    read -p "請輸入 Hysteria 2 端口 (1-65535): " input_port
    if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
      HY_PORT=$input_port
      break
    else
      echo -e "${RED}請輸入正確的端口數字 (1-65535)！${PLAIN}"
    fi
  done
else
  HY_PORT=$CUSTOM_PORT
fi

# 密碼處理：全自動生成
if [ -z "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$(gen_password)
  echo -e "${YELLOW}未指定密碼，已自動生成隨機密碼: $HY_PASS${PLAIN}"
else
  HY_PASS=$CUSTOM_PASSWORD
fi

echo -e "${GREEN}=== 開始安裝 Hysteria 2 ===${PLAIN}"
echo -e "端口: $HY_PORT 密碼: $HY_PASS"

echo -e "${YELLOW}[1/6] 分步安裝依賴（減少記憶體峰值佔用）...${PLAIN}"
apk update -q

# 挨個輕量化安裝，防止併發記憶體暴漲
for pkg in bash curl wget openssl tar iproute2 file; do
  echo -e " 正在安裝 $pkg..."
  apk add --no-cache -q $pkg || echo -e "${YELLOW}警告: $pkg 安裝遇到非致命異常，嘗試繼續...${PLAIN}"
done

mkdir -p /usr/local/bin /etc/ssl/private /etc/hysteria /var/log

# 2. 下載
echo -e "${YELLOW}[2/6] 下載 Hysteria 2 (自動重試多鏡像)...${PLAIN}"
ARCH_TYPE=$(get_arch); BIN_NAME="hysteria-linux-${ARCH_TYPE}"; DEST="/usr/local/bin/hysteria"
URLS=(
"https://github.com{BIN_NAME}"
"https://ghfast.top/https://github.com{BIN_NAME}"
"https://ghproxy.com/https://github.com{BIN_NAME}"
)
download_success=0
for URL in "${URLS[@]}"; do
  echo -e " 嘗試: $URL"
  rm -f "$DEST" /tmp/hy.download
  if curl -fL --connect-timeout 10 --max-time 60 -o /tmp/hy.download "$URL" 2>&1; then
    if head -c 20 /tmp/hy.download | grep -qi "<html"; then echo " -> 是HTML，跳過"; continue; fi
    if ! head -c 4 /tmp/hy.download | grep -q $'\x7fELF'; then echo " -> 不是ELF"; continue; fi
    SIZE=$(wc -c < /tmp/hy.download); if [ "$SIZE" -lt 2000000 ]; then echo " -> 太小 $SIZE"; continue; fi
    mv /tmp/hy.download "$DEST"; chmod +x "$DEST"; download_success=1; echo -e "${GREEN} -> 成功 ($SIZE bytes)${PLAIN}"; break
  else
    echo -e "${RED} -> 失敗，試下一個${PLAIN}"
  fi
done
if [ "$download_success" -ne 1 ]; then echo -e "${RED}所有鏡像失敗${PLAIN}"; exit 1; fi
"$DEST" version

# 3. 證書
echo -e "${YELLOW}[3/6] 生成 TLS 證書...${PLAIN}"
openssl ecparam -genkey -name prime256v1 -noout -out /etc/ssl/private/bing.key
openssl req -new -x509 -nodes -key /etc/ssl/private/bing.key -out /etc/ssl/private/bing.crt -days 3650 -subj "/CN=bing.com"
chmod 600 /etc/ssl/private/bing.key; chmod 644 /etc/ssl/private/bing.crt

# 4. 配置
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
depend() {
  need net
  after firewall
}
start_pre() {
  checkpath --directory --mode 0755 /run/hysteria
  checkpath --file --mode 0644 /var/log/hysteria.log
}
SERVICE_EOF
chmod +x /etc/init.d/hysteria
rc-update add hysteria default

# 6. 啟動與嚴格檢測
echo -e "${YELLOW}[6/6] 啟動服務...${PLAIN}"
rc-service hysteria restart || rc-service hysteria start
sleep 2

if ! rc-service hysteria status >/dev/null 2>&1; then
  echo -e "${RED}服務啟動失敗！錯誤日誌如下：${PLAIN}"
  cat /var/log/hysteria.log
  exit 1
fi

# === 智慧 IP 檢測模組 ===
get_public_ip() {
  local ip=""
  for api in "https://ifconfig.me" "https://ipinfo.io" "https://ipify.org" "https://icanhazip.com"; do
    ip=$(curl -4 -s --max-time 5 "$api" 2>/dev/null | tr -d ' \r\n' | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -n1)
    if [ -n "$ip" ]; then echo "$ip"; return; fi
  done
  echo ""
}

get_default_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1
}

# 獲取當前 SSH 階段的伺服器端 IP
get_ssh_server_ip() {
  if [ -n "$SSH_CONNECTION" ]; then
    echo "$SSH_CONNECTION" | awk '{print $3}'
  else
    echo ""
  fi
}

if [ -n "$CUSTOM_IP" ]; then
  SERVER_IP="$CUSTOM_IP"
  echo -e "${GREEN}使用手動指定的入口IP: $SERVER_IP${PLAIN}"
else
  SSH_IP=$(get_ssh_server_ip)
  if [ -n "$SSH_IP" ] && [[ "$SSH_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$SSH_IP" != "127.0.0.1" ]; then
    SERVER_IP="$SSH_IP"
    echo -e "${GREEN}智慧檢測：成功自動提取當前 SSH 連線的目的地 IP: $SERVER_IP${PLAIN}"
  else
    echo -e "${YELLOW}未檢測到有效 SSH 環境變數，切換至傳統探測模式...${PLAIN}"
    PUBLIC_IP=$(get_public_ip)
    LOCAL_IP=$(get_default_ip)
    echo -e "檢測到 出口公網IP: ${YELLOW}${PUBLIC_IP:-未知}${PLAIN}"
    echo -e "檢測到 本機默認路由IP: ${YELLOW}${LOCAL_IP:-未知}${PLAIN}"
    
    if [ -n "$PUBLIC_IP" ]; then SERVER_IP="$PUBLIC_IP"; else SERVER_IP="$LOCAL_IP"; fi
  fi
  
  if [ -z "$SERVER_IP" ]; then SERVER_IP="YOUR_SERVER_IP"; fi
fi

echo ""
echo -e "${GREEN}========== 安裝完成 ==========${PLAIN}"
echo -e "端口: ${GREEN}${HY_PORT}/udp${PLAIN} 密碼: ${GREEN}${HY_PASS}${PLAIN}"
echo -e "配置: /etc/hysteria/config.yaml"
echo -e "管理: rc-service hysteria restart"
echo ""
echo -e "客戶端 YAML:"
echo "server: ${SERVER_IP}:${HY_PORT}"
echo "auth: ${HY_PASS}"
echo "tls:"
echo "  sni: bing.com"
echo "  insecure: true"
echo ""
echo -e "URI 節點連結:"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Alpine-Hy2${PLAIN}"
echo ""
echo -e "${YELLOW}記得放行防火牆 UDP ${HY_PORT}${PLAIN}"
