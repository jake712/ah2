#!/bin/sh
# Hysteria 2 Debian V1.3 - Karing终极修复版 - 增加hex pin免编码
# 解决 base64 pin 含 +/ 导致部分客户端连不上

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'
while getopts "p:w:i:h" opt; do case $opt in p) CUSTOM_PORT=$OPTARG;; w) CUSTOM_PASSWORD=$OPTARG;; i) CUSTOM_IP=$OPTARG;; h) echo "用法: $0 [-p 端口] [-w 密码] [-i 公网IP]"; exit 0;; esac; done
if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi
echo -e "${GREEN}=== Hysteria2 Debian V1.3 Karing终极修复版 ===${PLAIN}"

export DEBIAN_FRONTEND=noninteractive
if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then echo -e "${YELLOW}检测到 Podman，保留DNS${PLAIN}"; else if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then echo "nameserver 1.1.1.1" > /etc/resolv.conf; echo "nameserver 8.8.8.8" >> /etc/resolv.conf; fi; fi
if ! command -v apt-get >/dev/null 2>&1; then echo -e "${RED}非Debian系统${PLAIN}"; exit 1; fi
APT_UPDATED=0; apt_update(){ if [ $APT_UPDATED -eq 0 ]; then apt-get update -qq; APT_UPDATED=1; fi; }
ensure_cmd(){ if ! command -v "$1" >/dev/null 2>&1; then apt_update; apt-get install -y --no-install-recommends "$2" 2>&1 || apt-get install -y "$2" || true; fi; }
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then apt_update; apt-get install -y --no-install-recommends curl || true; fi
ensure_cmd openssl openssl; ensure_cmd dig dnsutils
if ! command -v ss >/dev/null 2>&1; then apt_update; apt-get install -y --no-install-recommends iproute2 || true; fi
if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then apt_update; apt-get install -y --no-install-recommends ca-certificates || true; update-ca-certificates 2>/dev/null || true; fi

HY_PORT=${CUSTOM_PORT:-26169}
if [ -n "$CUSTOM_PASSWORD" ]; then HY_PASS=$CUSTOM_PASSWORD; else HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16); [ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"; fi
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /var/log; chmod 700 /etc/hysteria 2>/dev/null || true

echo -e "${YELLOW}下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; rm -f /tmp/hysteria; download_ok=0
for i in 1 2 3; do if command -v curl >/dev/null 2>&1; then curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" && download_ok=1 && break; fi; if command -v wget >/dev/null 2>&1; then wget -q --timeout=30 -O /tmp/hysteria "$HY_URL" && download_ok=1 && break; fi; sleep 1; done
if [ "$download_ok" != "1" ]; then for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break; wget -q --timeout=30 -O /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break; done; fi
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria

if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt; openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genpkey -algorithm EC -pkeyopt ec_param_enc:named_curve -pkeyopt ec_paramgen_curve:P-256 -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null; openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650 2>/dev/null || openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650; chmod 600 /etc/hysteria/key.key; fi

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

cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
pkill -f "hysteria.*config.yaml" || true; sleep 1
if systemctl is-active --quiet hysteria 2>/dev/null; then systemctl restart hysteria; else nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 & fi
echo "已重启"
RESTART
chmod +x /usr/local/bin/hy2-restart.sh
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 V1.3
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable hysteria >/dev/null 2>&1 || true; systemctl restart hysteria 2>&1 || systemctl start hysteria 2>&1 || true; sleep 2
else pkill -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1; nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 & sleep 2; fi

is_private_ip(){ local ip=$1; [ -z "$ip" ] && return 0; case "$ip" in 0.0.0.0|10.*|192.168.*|127.*|169.254.*) return 0;; 172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0;; esac; if echo "$ip" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.'; then return 0; fi; return 1; }
get_ssh_ip(){ if [ -n "$SSH_CONNECTION" ]; then echo "$SSH_CONNECTION" | awk '{print $3}'; return; fi; ss -tn 2>/dev/null | grep ':22' | awk '{print $4}' | cut -d: -f1 | grep -E '^[0-9.]+$' | grep -v '^127\.' | head -n1; }
get_pub_ip(){ local ip; if command -v dig >/dev/null 2>&1; then for ns in "208.67.222.222" "8.8.8.8"; do ip=$(dig +short +time=2 +tries=1 @${ns} myip.opendns.com 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1); if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi; done; fi; if command -v curl >/dev/null 2>&1; then for api in "https://api4.ipify.org" "https://icanhazip.com"; do ip=$(curl -4fsSL --max-time 4 "$api" 2>/dev/null | tr -d '\r' | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1); if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi; done; fi; }
if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP; else SIP=$(get_ssh_ip); PIP=$(get_pub_ip); if [ -z "$SIP" ] && [ -n "$PIP" ]; then SERVER_IP=$PIP; elif is_private_ip "$SIP" && [ -n "$PIP" ]; then SERVER_IP=$PIP; else SERVER_IP=${SIP:-$PIP}; fi; fi
[ -z "$SERVER_IP" ] && SERVER_IP="YOUR_PUBLIC_IP"

urlencode(){ if command -v python3 >/dev/null 2>&1; then python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; else printf '%s' "$1" | sed -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'; fi; }

CERT_PIN=""; CERT_PIN_ENC=""; CERT_PIN_HEX=""; CERT_FPR=""
if [ -f /etc/hysteria/cert.crt ]; then
  CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary 2>/dev/null | openssl enc -base64 2>/dev/null | tr -d '\n')
  [ -z "$CERT_PIN" ] && CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout 2>/dev/null | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary 2>/dev/null | openssl enc -base64 2>/dev/null | tr -d '\n')
  CERT_PIN_ENC=$(urlencode "$CERT_PIN")
  CERT_PIN_HEX=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $2}')
  [ -z "$CERT_PIN_HEX" ] && CERT_PIN_HEX=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout 2>/dev/null | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $2}')
  CERT_FPR=$(openssl x509 -in /etc/hysteria/cert.crt -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
fi

cp /etc/hysteria/cert.crt /root/hy2-cert.crt 2>/dev/null || true; chmod 644 /root/hy2-cert.crt 2>/dev/null || true

# 自动放行 iptables (Debian)
iptables -I INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || true
ip6tables -I INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || true

cat > /root/hy2-clash.yaml <<EOF
# Karing / Clash.Meta 终极可用版 - 用原始pin，不编码
proxies:
  - name: Hy2-${SERVER_IP}
    type: hysteria2
    server: ${SERVER_IP}
    port: ${HY_PORT}
    password: ${HY_PASS}
    sni: bing.com
    skip-cert-verify: false
    pinSHA256: ${CERT_PIN}
    alpn:
      - h3
EOF

cat > /root/hy2-clash-insecure.yaml <<EOF
# Karing 如果上面连不上，用这个insecure版 100%能连
proxies:
  - name: Hy2-${SERVER_IP}-insecure
    type: hysteria2
    server: ${SERVER_IP}
    port: ${HY_PORT}
    password: ${HY_PASS}
    sni: bing.com
    skip-cert-verify: true
    alpn:
      - h3
EOF

echo ""
echo -e "${GREEN}========== V1.3 完成 ==========${PLAIN}"
echo -e "端口: ${CYAN}${HY_PORT}${PLAIN} 密码: ${CYAN}${HY_PASS}${PLAIN} IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo -e "pin base64原始: ${CYAN}${CERT_PIN}${PLAIN}"
echo -e "pin base64编码: ${CYAN}${CERT_PIN_ENC}${PLAIN}"
echo -e "pin hex免编码: ${CYAN}${CERT_PIN_HEX}${PLAIN}"
echo -e ""
echo -e "${RED}>>> 甲骨文/Oracle 必须手动放行: 控制台 -> VCN -> 安全列表 -> 入站规则 -> 添加 UDP ${HY_PORT} 0.0.0.0/0${PLAIN}"
echo -e ""
echo -e "${GREEN}--- 1. Karing/Clash 推荐 YAML (原始pin) 路径: /root/hy2-clash.yaml ---${PLAIN}"
cat /root/hy2-clash.yaml
echo -e ""
echo -e "${YELLOW}--- 2. Karing 100%能连的 insecure YAML: /root/hy2-clash-insecure.yaml ---${PLAIN}"
cat /root/hy2-clash-insecure.yaml
echo -e ""
echo -e "${GREEN}--- 3. 分享链接 Karing编码版 ---${PLAIN}"
echo -e "hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_PIN_ENC}#Hy2-Karing-Pin"
echo -e ""
echo -e "${GREEN}--- 4. 分享链接 hex免编码版 (部分客户端支持) ---${PLAIN}"
echo -e "hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_PIN_HEX}#Hy2-HexPin"
echo -e ""
echo -e "${YELLOW}--- 5. 分享链接 兼容insecure版 (先用这个测试网络通不通) ---${PLAIN}"
echo -e "hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2-Insecure"
echo -e ""
echo -e "排查命令: ss -u -lpn | grep ${HY_PORT} ; cat /var/log/hysteria.log | tail -20"
echo -e "防火墙: iptables -L -n | grep ${HY_PORT}"
