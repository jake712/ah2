#!/bin/sh
# Hysteria 2 Debian V1.0 - NAT/Podman/LXC 低内存兼容 + v2n/Karing证书修复版

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

while getopts "p:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 端口] [-w 密码] [-i 公网IP]"; exit 0 ;;
  esac
done

if [ "$(id -u)"!= "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

echo -e "${GREEN}=== Hysteria2 Debian V1.0 Podman修复版 ===${PLAIN}"

# ===== [1/6] 基础依赖 =====
echo -e "${YELLOW}[1/6] 检查依赖...${PLAIN}"
export DEBIAN_FRONTEND=noninteractive
if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "${YELLOW}检测到 Podman (dns.podman)，保留原有 DNS${PLAIN}"
else
  if [! -s /etc/resolv.conf ] ||! grep -q "nameserver" /etc/resolv.conf; then
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi
if! command -v apt-get >/dev/null 2>&1; then echo -e "${RED}不是 Debian/Ubuntu${PLAIN}"; exit 1; fi
APT_UPDATED=0
apt_update(){ if [ $APT_UPDATED -eq 0 ]; then apt-get update -qq; APT_UPDATED=1; fi; }
ensure_cmd(){
  if! command -v "$1" >/dev/null 2>&1; then
    apt_update; apt-get install -y --no-install-recommends "$2" 2>&1 || apt-get install -y "$2" || true
  fi
}
if! command -v curl >/dev/null 2>&1 &&! command -v wget >/dev/null 2>&1; then apt_update; apt-get install -y --no-install-recommends curl || true; fi
ensure_cmd openssl openssl
ensure_cmd dig dnsutils
if! command -v ss >/dev/null 2>&1; then apt_update; apt-get install -y --no-install-recommends iproute2 || true; fi
if [! -f /etc/ssl/certs/ca-certificates.crt ]; then apt_update; apt-get install -y --no-install-recommends ca-certificates || true; update-ca-certificates 2>/dev/null || true; fi

# ===== [2/6] 参数和路径 =====
echo -e "${YELLOW}[2/6] 初始化参数...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-26169}
if [ -n "$CUSTOM_PASSWORD" ]; then HY_PASS=$CUSTOM_PASSWORD
else
  if command -v openssl >/dev/null 2>&1; then HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  else HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16); fi
fi
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64" ;; aarch64|arm64) HY_ARCH="arm64" ;; armv7l|arm) HY_ARCH="arm" ;; *) HY_ARCH="amd64" ;; esac
mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log
chmod 700 /etc/hysteria 2>/dev/null || true

# ===== [3/6] 下载 =====
echo -e "${YELLOW}[3/6] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria; download_ok=0
for i in 1 2 3; do
  if command -v curl >/dev/null 2>&1; then curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" && download_ok=1 && break; fi
  if command -v wget >/dev/null 2>&1; then wget -q --timeout=30 -O /tmp/hysteria "$HY_URL" && download_ok=1 && break; fi
  sleep 1
done
if [ "$download_ok"!= "1" ] || [! -s /tmp/hysteria ]; then
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
    wget -qO- --timeout=30 -O /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
  done
fi
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria
/usr/local/bin/hysteria version 2>&1 || true

# ===== [4/6] 生成证书和配置 =====
echo -e "${YELLOW}[4/6] 生成配置...${PLAIN}"
if [! -f /etc/hysteria/cert.crt ] || [! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || \
  openssl genpkey -algorithm EC -pkeyopt ec_param_enc:named_curve -pkeyopt ec_paramgen_curve:P-256 -out /etc/hysteria/key.key 2>/dev/null || \
  openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650 2>/dev/null
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

# ===== [5/6] 服务 =====
echo -e "${YELLOW}[5/6] 配置服务...${PLAIN}"
cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
pkill -f "hysteria.*config.yaml" || true; sleep 1
if systemctl is-active --quiet hysteria 2>/dev/null; then systemctl restart hysteria
else nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 & fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Server
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
  systemctl daemon-reload; systemctl enable hysteria >/dev/null 2>&1 || true; systemctl restart hysteria || systemctl start hysteria || true; sleep 2
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 & sleep 2
fi

# ===== [6/6] IP检测 + 新增 v2n/Karing 证书生成 =====
echo -e "${YELLOW}[6/6] IP检测 + 生成v2n/Karing配置...${PLAIN}"
is_private_ip(){ case "$1" in 0.0.0.0|10.*|192.168.*|127.*|169.254.*) return 0;; 172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0;; esac; echo "$1" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.' && return 0; return 1; }
get_ssh_ip(){ [ -n "$SSH_CONNECTION" ] && echo "$SSH_CONNECTION" | awk '{print $3}' && return; ss -tn 2>/dev/null | grep ':22' | awk '{print $4}' | cut -d: -f1 | grep -E '^[0-9.]+$' | grep -v '^127\.' | head -n1; }
get_pub_ip(){
  local ip; if command -v dig >/dev/null 2>&1; then for ns in 208.67.222.222 8.8.8.8 1.1.1.1; do ip=$(dig +short +time=2 +tries=1 @${ns} myip.opendns.com 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1); [ -n "$ip" ] &&! is_private_ip "$ip" && echo "$ip" && return; done; fi
  if command -v curl >/dev/null 2>&1; then for api in https://api4.ipify.org https://ifconfig.me/ip https://icanhazip.com; do ip=$(curl -4fsSL --max-time 4 "$api" 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1); [ -n "$ip" ] &&! is_private_ip "$ip" && echo "$ip" && return; done; fi
}
if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP
else SIP=$(get_ssh_ip); PIP=$(get_pub_ip); if [ -z "$SIP" ] && [ -n "$PIP" ]; then SERVER_IP=$PIP; elif is_private_ip "$SIP" 2>/dev/null && [ -n "$PIP" ]; then SERVER_IP=$PIP; else SERVER_IP=${SIP:-$PIP}; fi
fi
[ -z "$SERVER_IP" ] && SERVER_IP="YOUR_PUBLIC_IP"

# ---
