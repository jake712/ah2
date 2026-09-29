#!/bin/sh
# Hysteria 2 Alpine V3.3 - 自動跟隨SSH入口IP最終版
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

if [ "$(id -u)" != "0" ]; then echo -e "${RED}請用 root 運行${PLAIN}"; exit 1; fi

# DNS
echo -e "${YELLOW}[0/6] 優化DNS...${PLAIN}"
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 223.5.5.5
EOF

get_arch() {
  case $(uname -m) in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "amd64" ;;
  esac
}
gen_pass() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; }

# 端口
if [ -z "$CUSTOM_PORT" ]; then
  while true; do
    printf "請輸入端口 (1-65535): "
    read INP
    case "$INP" in
      ''|*[!0-9]*)
        echo -e "${RED}只能輸入數字${PLAIN}"
        continue
        ;;
      *)
        if [ "$INP" -ge 1 ] && [ "$INP" -le 65535 ]; then
          HY_PORT=$INP
          break
        else
          echo -e "${RED}範圍 1-65535${PLAIN}"
        fi
        ;;
    esac
  done
else
  HY_PORT=$CUSTOM_PORT
fi

if [ -z "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$(gen_pass)
  echo -e "${YELLOW}自動生成密碼: $HY_PASS${PLAIN}"
else
  HY_PASS=$CUSTOM_PASSWORD
fi

echo -e "${GREEN}=== 開始安裝 ===${PLAIN}"

# 依賴
apk update
for p in curl wget openssl tar iproute2 file procps openssh; do
  apk add --no-cache $p || true
done
mkdir -p /usr/local/bin /etc/ssl/private /etc/hysteria /var/log /run/hysteria

# 下載
ARCH=$(get_arch)
if [ "$ARCH" = "arm64" ]; then BIN="hysteria-linux-arm64"; else BIN="hysteria-linux-amd64"; fi
BASE="https://github.com/apernet/hysteria/releases/latest/download/${BIN}"
DEST="/usr/local/bin/hysteria"
URLS="$BASE https://ghps.cc/$BASE https://ghproxy.net/$BASE https://ghfast.top/$BASE https://github.moeyy.xyz/$BASE"

ok=0
for U in $URLS; do
  echo " 嘗試 $U"
  rm -f /tmp/hy.down
  if curl -fL --connect-timeout 10 --max-time 120 -o /tmp/hy.down "$U" 2>&1; then
    if head -c 200 /tmp/hy.down | grep -qi "<html"; then echo "  -> HTML跳過"; continue; fi
    SIZE=$(wc -c < /tmp/hy.down)
    if [ "$SIZE" -lt 4000000 ]; then echo "  -> 文件過小跳過"; continue; fi
    mv /tmp/hy.down $DEST
    chmod +x $DEST
    ok=1
    break
  fi
done
if [ "$ok" -ne 1 ]; then echo -e "${RED}下載失敗${PLAIN}"; exit 1; fi
$DEST version

# 證書
openssl ecparam -genkey -name prime256v1 -noout -out /etc/ssl/private/bing.key
openssl req -new -x509 -nodes -key /etc/ssl/private/bing.key -out /etc/ssl/private/bing.crt -days 3650 -subj "/CN=bing.com"

# 配置
cat > /etc/hysteria/config.yaml <<EOC
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
EOC

cat > /etc/init.d/hysteria <<'EOS'
#!/sbin/openrc-run
name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
depend() { need net; after firewall; }
start_pre() { checkpath --directory --mode 0755 /run/hysteria; }
EOS
chmod +x /etc/init.d/hysteria
rc-update add hysteria default
rc-service hysteria restart || rc-service hysteria start
sleep 2

# ===== V3.3 核心：自動跟隨SSH IP =====
get_ssh_ip() {
  # 方法1: 當前環境
  if [ -n "$SSH_CONNECTION" ]; then
    echo "$SSH_CONNECTION" | awk '{print $3}' | grep -E '^[0-9.]+$' | grep -v '^127\.'
    return
  fi
  # 方法2: 從 /proc 找回被sudo弄丟的
  if [ -d /proc ]; then
    for f in /proc/[0-9]*/environ; do
      [ -f "$f" ] || continue
      ip=$(tr '\0' '\n' < "$f" 2>/dev/null | grep '^SSH_CONNECTION=' | cut -d= -f2 | awk '{print $3}')
      if echo "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        if [ "$ip" != "127.0.0.1" ] && [ -n "$ip" ]; then
          echo "$ip"
          return
        fi
      fi
    done
  fi
  # 方法3: ss 連線反推
  ss -Htn 2>/dev/null | grep ':22' | awk '{print $4}' | cut -d: -f1 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n1
}

get_pub_ip() {
  curl -4s --max-time 3 https://ifconfig.me 2>/dev/null | grep -Eo '[0-9.]{7,15}' | head -n1
}

echo -e "${YELLOW}[6/6] IP檢測...${PLAIN}"
if [ -n "$CUSTOM_IP" ]; then
  SERVER_IP=$CUSTOM_IP
  echo -e "${GREEN}手動指定 -i: $SERVER_IP${PLAIN}"
else
  SIP=$(get_ssh_ip)
  PIP=$(get_pub_ip)
  echo -e " 檢測到 SSH入口IP: ${GREEN}${SIP:-未找到}${PLAIN}"
  echo -e " 檢測到 出口公網IP: ${YELLOW}${PIP:-未知}${PLAIN}"
  if [ -n "$SIP" ]; then
    SERVER_IP=$SIP
    echo -e "${GREEN}>> 自動採用 SSH入口IP: $SERVER_IP (可連)${PLAIN}"
  else
    SERVER_IP=$PIP
    echo -e "${YELLOW}>> 未找到SSH IP，採用出口IP: $SERVER_IP${PLAIN}"
  fi
fi

echo ""
echo -e "${GREEN}========== 完成 ==========${PLAIN}"
echo -e "hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Alpine-Hy2"
