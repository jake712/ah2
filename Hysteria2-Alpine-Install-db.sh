#!/bin/bash
# Hysteria2 Debian V4.0 - 支持指定出口IP + 自動綁定 + 策略路由
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

while getopts "p:w:i:o:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    o) CUSTOM_OUT_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 端口] [-w 密码] [-i 连接IP] [-o 出口IP]"; exit 0 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

HY_PORT=${CUSTOM_PORT:-26169}
if [ -n "$CUSTOM_PASSWORD" ]; then HY_PASS=$CUSTOM_PASSWORD
else HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16); [ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"; fi

if [ -n "$CUSTOM_OUT_IP" ]; then OUTBOUND_IP=$CUSTOM_OUT_IP
elif [ -n "$CUSTOM_IP" ]; then OUTBOUND_IP=$CUSTOM_IP
else OUTBOUND_IP=""; fi

echo -e "${GREEN}=== Hysteria2 V4.0 出口IP版 ===${PLAIN}"
[ -n "$OUTBOUND_IP" ] && echo -e "指定出口: ${CYAN}${OUTBOUND_IP}${PLAIN}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget openssl iproute2 iptables ca-certificates 2>/dev/null || true
command -v dig >/dev/null 2>&1 || apt-get install -y dnsutils bind9-dnsutils || true

ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin; chmod 700 /etc/hysteria

# ===== 核心修復：確保出口IP可用 =====
ensure_outbound_ip() {
  local ip=$1
  [ -z "$ip" ] && return 0
  local dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
  [ -z "$dev" ] && dev=$(ip route | grep default | awk '{print $5}' | head -n1)
  [ -z "$dev" ] && dev="eth0"
  local gw=$(ip route | grep '^default' | awk '{print $3}' | head -n1)
  
  echo -e "${YELLOW}檢測網卡: $dev 網關: $gw${PLAIN}"
  sysctl -w net.ipv4.ip_nonlocal_bind=1 >/dev/null 2>&1 || true

  if ! ip -4 addr show | grep -w "$ip" >/dev/null; then
    echo -e "${YELLOW}本機沒有 $ip，嘗試綁定到 $dev...${PLAIN}"
    ip addr add ${ip}/32 dev $dev 2>/dev/null || ip addr add ${ip}/24 dev $dev 2>/dev/null || echo -e "${RED}綁定失敗，可能是浮動IP/NAT，需要在廠商後台綁定${PLAIN}"
  fi
  
  # 策略路由
  if [ -n "$gw" ]; then
    ip rule add from $ip table 100 2>/dev/null || true
    ip route replace default via $gw dev $dev table 100 2>/dev/null || ip route add default via $gw dev $dev table 100 2>/dev/null || true
    ip route flush cache 2>/dev/null || true
  fi

  # SNAT 保底 - 這才是讓附加IP真正出口的關鍵
  iptables -t nat -D POSTROUTING -o $dev -j SNAT --to-source $ip 2>/dev/null || true
  iptables -t nat -I POSTROUTING -o $dev -j SNAT --to-source $ip 2>/dev/null || true
  echo -e "${GREEN}已加入 SNAT: $dev -> $ip${PLAIN}"

  # 測試
  echo -e "測試出口: curl --interface $ip ifconfig.me"
  curl --interface $ip -4fsSL --max-time 5 ifconfig.me || echo -e "${RED}測試失敗，但Hy2仍會嘗試使用該IP${PLAIN}"
}

[ -n "$OUTBOUND_IP" ] && ensure_outbound_ip "$OUTBOUND_IP"

# ===== 下載 Hy2 =====
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" || wget -q --timeout=30 -O /tmp/hysteria "$HY_URL"
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria

# ===== 證書 =====
if [ ! -f /etc/hysteria/cert.crt ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  chmod 600 /etc/hysteria/key.key
fi
CERT_PIN_HEX=$(openssl x509 -noout -fingerprint -sha256 -in /etc/hysteria/cert.crt | cut -d'=' -f2 | tr -d ':' | tr 'A-Z' 'a-z')

# ===== 配置 - 關鍵在這裡 =====
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

# 只有指定了出口才加這段
if [ -n "$OUTBOUND_IP" ]; then
cat >> /etc/hysteria/config.yaml <<EOF
outbounds:
    - name: direct
    type: direct
    direct:
      mode: auto
      bindIPv4: ${OUTBOUND_IP}
EOF
fi

# 放行防火牆
iptables -I INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || true
ufw allow ${HY_PORT}/udp 2>/dev/null || true

# ===== 服務 =====
cat > /etc/systemd/system/hysteria.service <<EOS
[Unit]
Description=Hysteria 2 Server V4.0
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOS
systemctl daemon-reload; systemctl enable hysteria >/dev/null 2>&1; systemctl restart hysteria; sleep 2
systemctl status hysteria --no-pager -l | head -n 20 || true
journalctl -u hysteria -n 20 --no-pager || true

# ===== 顯示 =====
is_private_ip() { case "$1" in 10.*|192.168.*|127.*) return 0;; esac; return 1; }
get_pub_ip() { curl -4fsSL --max-time 4 https://api4.ipify.org 2>/dev/null || curl -4fsSL --max-time 4 https://ifconfig.me 2>/dev/null; }
if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP; else SERVER_IP=$(get_pub_ip); fi

echo -e "${GREEN}========== 完成 ==========${PLAIN}"
echo -e "監聽: ${HY_PORT} 連接IP: ${SERVER_IP} 出口IP: ${OUTBOUND_IP:-系統預設}"
cat /etc/hysteria/config.yaml
echo -e "\n鏈接: hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2-V4.0"
