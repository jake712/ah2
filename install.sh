#!/bin/sh
# Hysteria 2 Alpine V4.2 - 離散端口跳動 + 低內存/Podman兼容 + IP檢測修復版
# 用法: curl -fsSL https://raw.githubusercontent.com/jake712/ah2/main/Install.sh | bash -s -- -p 26836 -r "20001,20005,30001" -i 160.187.0.21
# 支持: -r "20001,20005" 或 -r "20001,20002,30001-30010,50000" 或 -r "20000-50000"

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

HY_RANGE=""
while getopts "p:r:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    r) CUSTOM_RANGE=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 主端口] [-r \"離散端口,範圍\"] [-w 密碼] [-i 公網IP]"; exit 0 ;;
  esac
done

[ "$(id -u)" != "0" ] && echo -e "${RED}請用 root 運行${PLAIN}" && exit 1
echo -e "${GREEN}=== Hysteria2 Alpine V4.2 離散跳動+低內存版 ===${PLAIN}"
echo -e "容器ID: $(cat /etc/hostname 2>/dev/null || hostname) | 時間: $(date)"

# ===== [1/6] 低內存優化 =====
echo -e "${YELLOW}[1/6] 檢查依賴 (低內存模式)...${PLAIN}"
cat /proc/meminfo 2>/dev/null | grep -E "MemTotal|MemAvailable" || free -m 2>/dev/null || true

add_swap_if_needed() {
  if [ -f /proc/meminfo ]; then
    MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 999999)
    if [ "$MEM_KB" -lt 200000 ]; then
      if ! grep -q "swapfile" /proc/swaps 2>/dev/null; then
        echo -e "${YELLOW}檢測到低內存 ${MEM_KB}KB，創建 256M SWAP...${PLAIN}"
        rm -f /swapfile 2>/dev/null || true
        dd if=/dev/zero of=/swapfile bs=1M count=256 2>/dev/null || fallocate -l 256M /swapfile 2>/dev/null || true
        chmod 600 /swapfile 2>/dev/null; mkswap /swapfile 2>/dev/null; swapon /swapfile 2>/dev/null || true
      fi
    fi
  fi
  rm -rf /var/cache/apk/* 2>/dev/null || true
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
}
add_swap_if_needed

if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "${YELLOW}檢測到 Podman，保留原有 DNS${PLAIN}"
else
  [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf && echo "nameserver 1.1.1.1" > /etc/resolv.conf
fi

ensure_cmd() {
  CMD=$1; PKG=$2
  if command -v "$CMD" >/dev/null 2>&1; then echo "已存在: $CMD"; return 0; fi
  echo -e "${YELLOW}安裝缺失: $CMD ($PKG)...${PLAIN}"
  set +e
  apk add --no-cache --no-progress -q "$PKG" 2>&1
  RET=$?
  if [ $RET -ne 0 ]; then
    apk add --no-cache "$PKG" 2>&1
    RET=$?
  fi
  set -e
  [ $RET -ne 0 ] && echo -e "${RED}警告: $PKG 安裝失敗，嘗試繼續...${PLAIN}"
  return 0
}

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  apk add --no-cache --no-progress -q curl 2>&1 || apk add --no-cache curl 2>&1 || true
fi
ensure_cmd openssl openssl
ensure_cmd dig bind-tools || echo -e "${YELLOW}跳過 dig，將使用 curl 檢測IP${PLAIN}"
command -v ss >/dev/null 2>&1 || apk add --no-cache --no-progress -q iproute2 2>&1 || apk add --no-cache iproute2 2>&1 || true
command -v iptables >/dev/null 2>&1 || apk add --no-cache --no-progress -q iptables 2>&1 || apk add --no-cache iptables 2>&1 || true
[ -f /etc/ssl/certs/ca-certificates.crt ] || { apk add --no-cache ca-certificates 2>&1; update-ca-certificates 2>/dev/null || true; }

# ===== [2/6] 參數 =====
echo -e "${YELLOW}[2/6] 初始化參數...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-26169}
HY_RANGE=${CUSTOM_RANGE:-20001,20005,30001,40001,50001}
if [ -n "$CUSTOM_PASSWORD" ]; then HY_PASS=$CUSTOM_PASSWORD
else
  if command -v openssl >/dev/null 2>&1; then HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  else HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16); fi
fi
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log; chmod 700 /etc/hysteria

# ===== [3/6] 下載 =====
echo -e "${YELLOW}[3/6] 下載 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria; download_ok=0
for i in 1 2 3; do
  if command -v curl >/dev/null 2>&1; then curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" && download_ok=1 && break; fi
  if command -v wget >/dev/null 2>&1; then wget -q --timeout=30 -O /tmp/hysteria "$HY_URL" && download_ok=1 && break; fi
  sleep 1
done
if [ "$download_ok" != "1" ]; then
  for mirror in "https://ghfast.top/$HY_URL" "https://ghproxy.net/$HY_URL"; do curl -4fsSL -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break; done
fi
[ -s /tmp/hysteria ] || { echo -e "${RED}下載失敗${PLAIN}"; exit 1; }
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria

# ===== [4/6] 證書和配置 =====
echo -e "${YELLOW}[4/6] 生成配置...${PLAIN}"
if [ ! -f /etc/hysteria/cert.crt ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  chmod 600 /etc/hysteria/key.key
fi
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

# ===== [5/6] 服務 + 離散跳動核心 =====
echo -e "${YELLOW}[5/6] 配置服務 + 離散跳動...${PLAIN}"

setup_hopping() {
  [ -z "$HY_RANGE" ] && return 0
  echo -e "${YELLOW}[跳動] 離散端口列表: $HY_RANGE => 主端口 $HY_PORT${PLAIN}"
  echo "#!/bin/sh" > /usr/local/bin/hy2-iptables.sh
  echo "set -e" >> /usr/local/bin/hy2-iptables.sh
  # 用 , 分割，兼容 ash
  echo "$HY_RANGE" | tr ',' '\n' | while read -r token; do
    token=$(echo "$token" | tr -d ' ' | tr -d '\r')
    [ -z "$token" ] && continue
    ipt_token=$(echo "$token" | tr '-' ':')
    echo "$ipt_token" | grep -Eq '^[0-9:]+$' || { echo "跳過非法 $token"; continue; }
    echo "處理 $token -> $ipt_token"
    iptables -t nat -D PREROUTING -p udp --dport "$ipt_token" -j DNAT --to-destination :${HY_PORT} 2>/dev/null || true
    if ! iptables -t nat -A PREROUTING -p udp --dport "$ipt_token" -j DNAT --to-destination :${HY_PORT} 2>/dev/null; then
      echo -e "${RED}容器無 NET_ADMIN，宿主機需執行: iptables -t nat -A PREROUTING -p udp --dport $ipt_token -j DNAT --to :$HY_PORT${PLAIN}"
    fi
    echo "iptables -t nat -C PREROUTING -p udp --dport $ipt_token -j DNAT --to-destination :${HY_PORT} 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport $ipt_token -j DNAT --to-destination :${HY_PORT}" >> /usr/local/bin/hy2-iptables.sh
  done
  chmod +x /usr/local/bin/hy2-iptables.sh
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  mkdir -p /etc/local.d; echo "/usr/local/bin/hy2-iptables.sh" > /etc/local.d/hy2.start; chmod +x /etc/local.d/hy2.start; rc-update add local default 2>/dev/null || true
}

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
depend() { need net; }
start_pre() { checkpath --directory --mode 0755 /run/hysteria; /usr/local/bin/hy2-iptables.sh 2>/dev/null || true; }
EOS
  chmod +x /etc/init.d/hysteria; rc-update add hysteria default >/dev/null 2>&1; rc-service hysteria restart 2>&1 || rc-service hysteria start 2>&1 || true
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
setup_hopping
sleep 2; ss -tulpn 2>/dev/null | grep -E "$HY_PORT|hysteria" || true

# ===== [6/6] IP檢測 V3.7 修復版 =====
echo -e "${YELLOW}[6/6] IP檢測...${PLAIN}"
is_private_ip(){ case "$1" in 0.0.0.0|10.*|192.168.*|127.*|169.254.*) return 0;; 172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0;; esac; echo "$1" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.' && return 0; return 1; }
get_pub_ip(){
  local ip
  if command -v dig >/dev/null 2>&1; then
    for ns in 208.67.222.222 8.8.8.8 1.1.1.1; do ip=$(dig +short +time=2 +tries=1 @${ns} myip.opendns.com 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1); [ -n "$ip" ] && ! is_private_ip "$ip" && echo "$ip" && return; done
  fi
  if command -v curl >/dev/null 2>&1; then
    for api in https://api4.ipify.org https://ifconfig.me/ip https://ip.sb; do ip=$(curl -4fsSL --max-time 4 "$api" 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1); [ -n "$ip" ] && ! is_private_ip "$ip" && echo "$ip" && return; done
  fi
}
if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP; else SERVER_IP=$(get_pub_ip); [ -z "$SERVER_IP" ] && SERVER_IP="YOUR_PUBLIC_IP"; fi
MPORT=$(echo "$HY_RANGE" | tr ':' '-' | tr -d ' ')

echo -e "${GREEN}========== V4.2 完成 ==========${PLAIN}"
echo -e "主端口: ${CYAN}${HY_PORT}${PLAIN}  離散跳動: ${CYAN}${HY_RANGE}${PLAIN}"
echo -e "密碼: ${CYAN}${HY_PASS}${PLAIN}  IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo ""
echo -e "單端口:"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2${PLAIN}"
echo ""
echo -e "離散跳動 (推薦):"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&mport=${MPORT}&insecure=1#Hy2-Hop${PLAIN}"
echo ""
echo -e "日誌: tail -f /var/log/hysteria.log  記得放行 UDP ${HY_PORT} 和 ${HY_RANGE}"
