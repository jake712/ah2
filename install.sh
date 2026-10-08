#!/bin/sh
# Hysteria 2 Alpine V4.1 - 自定義離散端口跳動版
# 用法: -p 主端口 -r "20001,20005,30001-30010,50000" -w 密碼 -i IP
# 範例: bash install.sh -p 26169 -r "20001,20500,30001,40000-40010"

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

HY_RANGE=""
while getopts "p:r:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    r) CUSTOM_RANGE=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 主端口] [-r \"端口,端口,範圍\"] [-w 密碼] [-i 公網IP]"; exit 0 ;;
  esac
done

[ "$(id -u)" != "0" ] && echo -e "${RED}請用 root 運行${PLAIN}" && exit 1
echo -e "${GREEN}=== Hysteria2 Alpine V4.1 離散跳動版 ===${PLAIN}"

# 依賴
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || apk add --no-cache curl >/dev/null 2>&1
command -v iptables >/dev/null 2>&1 || apk add --no-cache iptables >/dev/null 2>&1
command -v openssl >/dev/null 2>&1 || apk add --no-cache openssl >/dev/null 2>&1
command -v dig >/dev/null 2>&1 || apk add --no-cache bind-tools >/dev/null 2>&1

HY_PORT=${CUSTOM_PORT:-26169}
HY_RANGE=${CUSTOM_RANGE:-20001,20005,30001,40001,50001}
HY_PASS=${CUSTOM_PASSWORD:-$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)}
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log; chmod 700 /etc/hysteria

# 下載
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
echo -e "${YELLOW}下載 Hysteria2...${PLAIN}"
curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" || wget -qO /tmp/hysteria "$HY_URL"
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria

# 證書
[ -f /etc/hysteria/cert.crt ] || {
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  chmod 600 /etc/hysteria/key.key
}
cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}
auth:
  type: password
  password: ${HY_PASS}
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
EOF

# ===== 核心：離散端口跳動 =====
setup_hopping() {
  [ -z "$HY_RANGE" ] && return 0
  echo -e "${YELLOW}[跳動] 解析離散端口: $HY_RANGE${PLAIN}"
  
  # 生成開機恢復腳本
  echo "#!/bin/sh" > /usr/local/bin/hy2-iptables.sh
  echo "set -e" >> /usr/local/bin/hy2-iptables.sh

  # 用 , 分割，兼容 ash
  echo "$HY_RANGE" | tr ',' '\n' | while read -r token; do
    token=$(echo "$token" | tr -d ' ' | tr -d '\r')
    [ -z "$token" ] && continue
    # iptables 格式要用 : , 客戶端要用 -
    ipt_token=$(echo "$token" | tr '-' ':')
    client_token=$(echo "$token" | tr ':' '-')

    # 簡單校驗
    echo "$ipt_token" | grep -Eq '^[0-9:]+$' || { echo -e "${RED}跳過非法: $token${PLAIN}"; continue; }

    echo -e "  -> ${CYAN}$client_token${PLAIN} => :$HY_PORT"
    # 先刪舊的防止重複
    iptables -t nat -D PREROUTING -p udp --dport "$ipt_token" -j DNAT --to-destination :${HY_PORT} 2>/dev/null || true
    if ! iptables -t nat -A PREROUTING -p udp --dport "$ipt_token" -j DNAT --to-destination :${HY_PORT} 2>/dev/null; then
      echo -e "${RED} 容器無權限，宿主機需手動執行: iptables -t nat -A PREROUTING -p udp --dport $ipt_token -j DNAT --to :$HY_PORT${PLAIN}"
    fi
    echo "iptables -t nat -C PREROUTING -p udp --dport $ipt_token -j DNAT --to-destination :${HY_PORT} 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport $ipt_token -j DNAT --to-destination :${HY_PORT}" >> /usr/local/bin/hy2-iptables.sh
  done

  chmod +x /usr/local/bin/hy2-iptables.sh
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  # OpenRC 持久化
  mkdir -p /etc/local.d; echo "/usr/local/bin/hy2-iptables.sh" > /etc/local.d/hy2.start; chmod +x /etc/local.d/hy2.start; rc-update add local default 2>/dev/null || true
}

# 啟動
if [ -f /sbin/openrc-run ]; then
  cat > /etc/init.d/hysteria <<'EOS'
#!/sbin/openrc-run
name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
start_pre(){ /usr/local/bin/hy2-iptables.sh 2>/dev/null || true; }
EOS
  chmod +x /etc/init.d/hysteria; rc-update add hysteria default >/dev/null 2>&1; rc-service hysteria restart >/dev/null 2>&1 || rc-service hysteria start
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true
  /usr/local/bin/hy2-iptables.sh 2>/dev/null || true
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi

setup_hopping

# IP檢測
get_pub_ip(){ curl -4fsSL --max-time 4 https://api4.ipify.org 2>/dev/null || dig +short +time=2 @8.8.8.8 myip.opendns.com 2>/dev/null; }
SERVER_IP=${CUSTOM_IP:-$(get_pub_ip)}; [ -z "$SERVER_IP" ] && SERVER_IP="YOUR_PUBLIC_IP"
MPORT=$(echo "$HY_RANGE" | tr ':' '-' | tr -d ' ')

echo -e "${GREEN}========== V4.1 完成 ==========${PLAIN}"
echo -e "主端口: $HY_PORT  離散跳動: $HY_RANGE"
echo -e "密碼: ${CYAN}$HY_PASS${PLAIN}"
echo -e "分享鏈 (離散跳動):"
echo -e "${GREEN}hysteria2://$HY_PASS@$SERVER_IP:$HY_PORT/?sni=bing.com&mport=$MPORT&insecure=1#Hy2-V4.1-Hop${PLAIN}"
