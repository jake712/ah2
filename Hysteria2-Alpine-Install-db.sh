#!/bin/bash
# Hysteria 2 Debian V3.9 - 修复v2rayN/Karing + 支持指定出口IP
# 基于 jake712 V3.8 改写
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

while getopts "p:w:i:o:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    o) CUSTOM_OUT_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 端口] [-w 密码] [-i 连接公网IP] [-o 出口IP]"; echo "示例: $0 -p 12428 -i 192.255.141.181 -o 192.255.141.181"; exit 0 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi
echo -e "${GREEN}=== Hysteria2 Debian V3.9 出口IP版 ===${PLAIN}"

# ===== 依赖 (和你原版一样) =====
echo -e "${YELLOW}[1/6] 检查依赖...${PLAIN}"
export DEBIAN_FRONTEND=noninteractive
if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then echo -e "Podman DNS 保留"; else [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf && echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf; fi
apt_update_done=0
apt_install() { if [ $apt_update_done -eq 0 ]; then apt-get update -qq; apt_update_done=1; fi; apt-get install -y -qq "$@" || apt-get install -y "$@"; }
ensure_cmd() { command -v "$1" >/dev/null 2>&1 && return 0; echo "安装缺失依赖: $2"; apt_install "$2"; }
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then apt_install curl wget; fi
ensure_cmd openssl openssl
if ! command -v dig >/dev/null 2>&1; then apt_install dnsutils || apt_install bind9-dnsutils || apt_install bind9-host; fi
command -v ss >/dev/null 2>&1 || apt_install iproute2
[ ! -f /etc/ssl/certs/ca-certificates.crt ] && apt_install ca-certificates && update-ca-certificates 2>/dev/null || true

# ===== 参数 =====
echo -e "${YELLOW}[2/6] 初始化...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-26169}
if [ -n "$CUSTOM_PASSWORD" ]; then HY_PASS=$CUSTOM_PASSWORD
else HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16); [ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"; fi
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; arm*) HY_ARCH="arm";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log; chmod 700 /etc/hysteria 2>/dev/null || true

# ===== 核心改动: 确定出口IP =====
# 如果给了 -o 就用 -o，否则如果给了 -i 就让 -i 兼任出口IP，否则不绑定(走系统默认路由)
if [ -n "$CUSTOM_OUT_IP" ]; then OUTBOUND_IP=$CUSTOM_OUT_IP
elif [ -n "$CUSTOM_IP" ]; then OUTBOUND_IP=$CUSTOM_IP
else OUTBOUND_IP=""; fi

if [ -n "$OUTBOUND_IP" ]; then echo -e "出口IP锁定为: ${CYAN}${OUTBOUND_IP}${PLAIN}"; fi

# ===== 下载 =====
echo -e "${YELLOW}[3/6] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria; download_ok=0
for i in 1 2 3; do curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" 2>/dev/null && download_ok=1 && break; wget -q --timeout=30 -O /tmp/hysteria "$HY_URL" 2>/dev/null && download_ok=1 && break; sleep 1; done
if [ "$download_ok" != "1" ]; then for mirror in "https://ghfast.top/$HY_URL" "https://ghproxy.net/$HY_URL"; do curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break; done; fi
[ ! -s /tmp/hysteria ] && echo -e "${RED}下载失败${PLAIN}" && exit 1
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria

# ===== 证书和配置 =====
echo -e "${YELLOW}[4/6] 生成证书和配置...${PLAIN}"
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  chmod 600 /etc/hysteria/key.key
fi
CERT_PIN_HEX=$(openssl x509 -noout -fingerprint -sha256 -in /etc/hysteria/cert.crt | cut -d'=' -f2 | tr -d ':' | tr 'A-Z' 'a-z')
CERT_PIN_B64=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')

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

# 关键: 如果指定了出口IP，就追加 outbounds
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

# ===== 服务 (和原版一样) =====
echo -e "${YELLOW}[5/6] 启动服务...${PLAIN}"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/hysteria.service <<EOS
[Unit]
Description=Hysteria 2 Server (Debian V3.9)
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
  systemctl daemon-reload; systemctl enable hysteria >/dev/null 2>&1 || true; systemctl restart hysteria || systemctl start hysteria; sleep 2
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/bash
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then systemctl restart hysteria && echo "已通过 systemd 重启" && exit 0; fi
pkill -f "hysteria.*config.yaml" || true; sleep 1; nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &; echo "已重启"
RESTART
chmod +x /usr/local/bin/hy2-restart.sh

# ===== IP检测和链接 (和原版一样) =====
is_private_ip() { case "$1" in 0.0.0.0|10.*|192.168.*|127.*|169.254.*) return 0;; 172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0;; esac; echo "$1" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.' && return 0; return 1; }
get_ssh_ip() { [ -n "$SSH_CONNECTION" ] && echo "$SSH_CONNECTION" | awk '{print $3}' && return; ss -tn 2>/dev/null | grep ':22' | awk '{print $4}' | cut -d: -f1 | grep -E '^[0-9.]+$' | grep -v '^127\.' | head -n1; }
get_pub_ip() { local ip; if command -v dig >/dev/null 2>&1; then for ns in "208.67.222.222" "8.8.8.8" "1.1.1.1"; do ip=$(dig +short +time=2 +tries=1 @${ns} myip.opendns.com 2>/dev/null | grep -Eo '[0-9.]{7,15}' | head -n1); [ -n "$ip" ] && ! is_private_ip "$ip" && echo "$ip" && return; done; fi; if command -v curl >/dev/null 2>&1; then for api in "https://api4.ipify.org" "https://ifconfig.me/ip" "https://ip.sb"; do ip=$(curl -4fsSL --max-time 4 "$api" 2>/dev/null | grep -Eo '[0-9.]{7,15}' | head -n1); [ -n "$ip" ] && ! is_private_ip "$ip" && echo "$ip" && return; done; fi; }
if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP; else SIP=$(get_ssh_ip); PIP=$(get_pub_ip); if is_private_ip "$SIP"; then [ -n "$PIP" ] && SERVER_IP=$PIP || SERVER_IP=$SIP; else [ -n "$SIP" ] && SERVER_IP=$SIP || SERVER_IP=$PIP; fi; fi
[ -z "$SERVER_IP" ] && SERVER_IP="YOUR_PUBLIC_IP"

echo -e "${YELLOW}[6/6] 生成客户端配置...${PLAIN}"
LINK_INSECURE="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Debian-Hy2-V3.9-Insecure"
LINK_PIN_HEX="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_PIN_HEX}#Debian-Hy2-V3.9-PIN"
LINK_PIN_B64="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_PIN_B64}#Debian-Hy2-V3.9-PIN-B64"
mkdir -p /root
cat > /root/hy2-links.txt <<EOF
端口: ${HY_PORT}
密码: ${HY_PASS}
连接IP: ${SERVER_IP}
出口IP: ${OUTBOUND_IP:-系统默认路由}
HEX PIN: ${CERT_PIN_HEX}

v2rayN:
${LINK_INSECURE}

Karing:
${LINK_PIN_HEX}
EOF
echo -e "${GREEN}完成! 连接IP:${SERVER_IP} 出口IP:${OUTBOUND_IP:-默认} ${PLAIN}"
echo -e "${LINK_INSECURE}"
cat /etc/hysteria/config.yaml
