#!/bin/sh
# Hysteria 2 一鍵安裝 for Alpine Linux V3.2 - POSIX兼容+入口IP修復版
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

get_arch() { case $(uname -m) in x86_64|amd64) echo "amd64";; aarch64|arm64) echo "arm64";; *) echo "amd64";; esac; }
gen_password() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; }

# === 修復點1：端口判斷不用 [[ =~ ]] ===
if [ -z "$CUSTOM_PORT" ]; then
  while true; do
    printf "請輸入 Hysteria 2 端口 (1-65535): "
    read input_port
    case "$input_port" in
      ''|*[!0-9]*)
        echo -e "${RED}請輸入正確的數字！${PLAIN}"; continue ;;
      *)
        if [ "$input_port" -ge 1 ] 2>/dev/null && [ "$input_port" -le 65535 ] 2>/dev/null; then
          HY_PORT=$input_port; break
        else
          echo -e "${RED}端口範圍 1-65535！${PLAIN}"
        fi
        ;;
    esac
  done
else
  HY_PORT=$CUSTOM_PORT
fi

if [ -z "$CUSTOM_PASSWORD" ]; then HY_PASS=$(gen_password); echo -e "${YELLOW}已自動生成: $HY_PASS${PLAIN}"; else HY_PASS=$CUSTOM_PASSWORD; fi

echo -e "${GREEN}=== 開始安裝 Hysteria 2 ===${PLAIN}"
echo -e "${YELLOW}[1/6] 安裝依賴...${PLAIN}"
apk update
for pkg in bash curl wget openssl tar iproute2 file procps; do apk add --no-cache $pkg || true; done
mkdir -p /usr/local/bin /etc/ssl/private /etc/hysteria /var/log /run/hysteria

echo -e "${YELLOW}[2/6] 下載 Hysteria 2...${PLAIN}"
ARCH_TYPE=$(get_arch); DEST="/usr/local/bin/hysteria"
if [ "$ARCH_TYPE" = "arm64" ]; then BIN_NAME="hysteria-linux-arm64"; else BIN_NAME="hysteria-linux-amd64"; fi
BASE="https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
URLS="${BASE} https://ghps.cc/${BASE} https://ghproxy.net/${BASE} https://ghfast.top/${BASE} https://github.moeyy.xyz/${BASE}"

download_success=0
for URL in $URLS; do
  echo -e " 嘗試: $URL"; rm -f /tmp/hy.download
  if curl -fL --connect-timeout 10 --max-time 120 -o /tmp/hy.download "$URL" 2>&1; then
    if head -c 200 /tmp/hy.download | grep -qi "<html"; then echo "  -> HTML跳過"; continue; fi
    if ! head -c 4 /tmp/hy.download | grep -q "$(printf '\x7fELF')"; then echo "  -> 非ELF跳過"; continue; fi
    mv /tmp/hy.download "$DEST"; chmod +x "$DEST"; download_success=1; echo -e "${GREEN} -> 成功${PLAIN}"; break
  fi
done
if [ "$download_success" -ne 1 ]; then echo -e "${RED}下載失敗${PLAIN}"; exit 1; fi
"$DEST" version

echo -e "${YELLOW}[3/6] 生成證書...${PLAIN}"
openssl ecparam -genkey -name prime256v1 -noout -out /etc/ssl/private/bing.key
openssl req -new -x509 -nodes -key /etc/ssl/private/bing.key -out /etc/ssl/private/bing.crt -days 3650 -subj "/CN=bing.com"
chmod 600 /etc/ssl/private/bing.key; chmod 644 /etc/ssl/private/bing.crt

echo -e "${YELLOW}[4/6] 生成配置...${PLAIN}"
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

cat > /etc/init.d/hysteria <<'SERVICE_EOF'
#!/sbin/openrc-run
name="Hysteria 2 Service"
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

echo -e "${YELLOW}[5/6] 啟動服務...${PLAIN}"
rc-service hysteria restart || rc-service hysteria start; sleep 2

# === 修復點2：V3.2 智慧IP檢測，完全不用 [[ ]] ===
get_public_ip() {
  for api in "https://ifconfig.me" "https://ipinfo.io/ip" "https://icanhazip.com"; do
    ip=$(curl -4 -s --max-time 5 "$api" 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
    if [ -n "$ip" ]; then echo "$ip"; return; fi
  done; echo ""
}
get_default_ip() { ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1; }
get_ssh_server_ip() {
  ip=""; 
  if [ -n "$SSH_CONNECTION" ]; then
    ip=$(echo "$SSH_CONNECTION" | awk '{print $3}')
    echo "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    if [ $? -eq 0 ] && [ "$ip" != "127.0.0.1" ]; then echo "$ip"; return; fi
  fi
  if [ -d /proc ]; then
    for pid in $(ps -o pid= 2>/dev/null); do
      if [ -f "/proc/$pid/environ" ]; then
        ip=$(tr '\0' '\n' < /proc/$pid/environ 2>/dev/null | grep '^SSH_CONNECTION=' | cut -d= -f2 | awk '{print $3}' | tail -n1)
        echo "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
        if [ $? -eq 0 ] && [ "$ip" != "127.0.0.1" ] && [ -n "$ip" ]; then echo "$ip"; return; fi
      fi
    done
  fi
  ip=$(ss -Htn state established '( dport = :22 or sport = :22 )' 2>/dev/null | awk '{print $4}' | cut -d: -f1 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n1)
  if [ -n "$ip" ]; then echo "$ip"; return; fi
  echo ""
}

echo -e "${YELLOW}[6/6] 檢測 IP...${PLAIN}"
if [ -n "$CUSTOM_IP" ]; then
  SERVER_IP="$CUSTOM_IP"
  echo -e "${GREEN}使用 -i 指定入口IP: $SERVER_IP${PLAIN}"
else
  SSH_IP=$(get_ssh_server_ip); PUBLIC_IP=$(get_public_ip); LOCAL_IP=$(get_default_ip)
  echo -e " SSH入口IP: ${GREEN}${SSH_IP:-未檢測到}${PLAIN}"
  echo -e " 出口公網IP: ${YELLOW}${PUBLIC_IP:-未知}${PLAIN}"
  echo -e " 本地路由IP: ${YELLOW}${LOCAL_IP:-未知}${PLAIN}"
  if [ -n "$SSH_IP" ]; then SERVER_IP="$SSH_IP"; echo -e "${GREEN}>> 已採用入口IP: $SERVER_IP${PLAIN}"
  elif [ -n "$PUBLIC_IP" ]; then SERVER_IP="$PUBLIC_IP"
  else SERVER_IP="$LOCAL_IP"; fi
fi
[ -z "$SERVER_IP" ] && SERVER_IP="YOUR_SERVER_IP"

echo ""; echo -e "${GREEN}========== 安裝完成 ==========${PLAIN}"
echo -e "URI: ${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Alpine-Hy2${PLAIN}"
