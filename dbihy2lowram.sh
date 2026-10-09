#!/bin/sh
# Hysteria 2 Debian V1.1 - 128MB低内存/Podman专用修复
# 修复 V1.0 在 128MB Debian 13 trixie 上 apt-get update 卡死问题

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

if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

TOTAL_MEM=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 999999)
if [ "$TOTAL_MEM" -lt 200000 ]; then
  LOW_MEM=1
  echo -e "${YELLOW}检测到低内存: ${TOTAL_MEM}kB (<200MB)，启用极简模式，跳过 dig/ss 安装${PLAIN}"
else
  LOW_MEM=0
fi

echo -e "${GREEN}=== Hysteria2 Debian V1.1 低内存版 ===${PLAIN}"

# ===== [1/6] 基础依赖 =====
echo -e "${YELLOW}[1/6] 检查依赖...${PLAIN}"
export DEBIAN_FRONTEND=noninteractive
cat /etc/resolv.conf | head -n 5
cat /proc/meminfo 2>/dev/null | grep -E "MemTotal|MemAvailable" || true

if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "${YELLOW}Podman DNS 10.91.0.1 保留，不覆盖${PLAIN}"
fi

if ! command -v apt-get >/dev/null 2>&1; then echo -e "${RED}不是 Debian${PLAIN}"; exit 1; fi

APT_UPDATED=0
apt_update() {
  if [ $APT_UPDATED -eq 1 ]; then return; fi
  # 低内存且已有缓存就跳过，Alpine逻辑同理
  if [ "$LOW_MEM" = "1" ] && [ -n "$(ls /var/lib/apt/lists 2>/dev/null | grep -v lock | grep -v partial)" ]; then
    echo -e "${YELLOW}低内存已有 apt 缓存，跳过 apt-get update${PLAIN}"
    APT_UPDATED=1
    return
  fi
  echo -e "${YELLOW}apt-get update (timeout 30s)...${PLAIN}"
  apt-get update -qq -o Acquire::Retries=1 -o Acquire::http::Timeout=10 2>&1 || \
  apt-get update -o Acquire::http::Timeout=15 2>&1 || echo -e "${YELLOW}update 失败，继续尝试${PLAIN}"
  APT_UPDATED=1
}

# 你现在卡住的位置就是这里，V1.1 改为可选
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  apt_update
  apt-get install -y --no-install-recommends curl || true
fi

# dig 在低内存下完全可选，不装
if [ "$LOW_MEM" = "0" ]; then
  if ! command -v dig >/dev/null 2>&1; then
    echo -e "${YELLOW}安装 dig (dnsutils)...${PLAIN}"
    apt_update
    apt-get install -y --no-install-recommends dnsutils || echo -e "${YELLOW}dnsutils 安装失败，跳过，后面用curl${PLAIN}"
  fi
  if ! command -v ss >/dev/null 2>&1; then
    apt_update
    apt-get install -y --no-install-recommends iproute2 || true
  fi
else
  echo -e "${YELLOW}低内存模式: 跳过 dig/ss，IP检测仅用 curl -4${PLAIN}"
fi

if command -v openssl >/dev/null 2>&1; then
  echo -e "已存在: openssl"
else
  apt_update; apt-get install -y --no-install-recommends openssl ca-certificates || true
fi

# ===== 后面 [2/6] - [6/6] 和你 V3.7 逻辑完全一样，省略粘贴，原样保留 =====
# 为了让你直接覆盖，我把完整版放在下面，你复制后面就行...
echo -e "${YELLOW}[2/6] 初始化参数...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-26169}
if [ -n "$CUSTOM_PASSWORD" ]; then HY_PASS=$CUSTOM_PASSWORD; else HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16); fi
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log; chmod 700 /etc/hysteria 2>/dev/null || true

echo -e "${YELLOW}[3/6] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria; download_ok=0
for i in 1 2 3; do if command -v curl >/dev/null 2>&1; then curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" && download_ok=1 && break; fi; if command -v wget >/dev/null 2>&1; then wget -q --timeout=30 -O /tmp/hysteria "$HY_URL" && download_ok=1 && break; fi; sleep 1; done
if [ "$download_ok" != "1" ] || [ ! -s /tmp/hysteria ]; then for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break; wget -q --timeout=30 -O /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break; done; fi
if [ ! -s /tmp/hysteria ]; then echo -e "${RED}下载失败${PLAIN}"; exit 1; fi
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria

echo -e "${YELLOW}[4/6] 生成配置...${PLAIN}"
if [ ! -f /etc/hysteria/cert.crt ]; then rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt; openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genpkey -algorithm EC -pkeyopt ec_param_enc:named_curve -pkeyopt ec_paramgen_curve:P-256 -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null; openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650 2>/dev/null || openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650; chmod 600 /etc/hysteria/key.key; fi
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

echo -e "${YELLOW}[5/6] 配置服务...${PLAIN}"
cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
pkill -f "hysteria.*config.yaml" || true; sleep 1
if systemctl is-active --quiet hysteria 2>/dev/null; then systemctl restart hysteria; else nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 & fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then cat > /etc/systemd/system/hysteria.service <<SERVICE
[Unit]
Description=Hysteria2
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload; systemctl enable hysteria >/dev/null 2>&1 || true; systemctl restart hysteria || true; sleep 2
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
ss -tulpn 2>/dev/null | grep -E "$HY_PORT|hysteria" || true

echo -e "${YELLOW}[6/6] IP检测...${PLAIN}"
is_private_ip(){ case "$1" in 0.0.0.0|10.*|192.168.*|127.*|169.254.*) return 0;; 172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0;; esac; echo "$1" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.' && return 0; return 1; }
get_ssh_ip(){ [ -n "$SSH_CONNECTION" ] && echo "$SSH_CONNECTION" | awk '{print $3}' && return; ss -tn 2>/dev/null | grep ':22' | awk '{print $4}' | cut -d: -f1 | grep -E '^[0-9.]+$' | grep -v '^127\.' | head -n1; }
get_pub_ip(){ local ip; if command -v dig >/dev/null 2>&1; then for ns in "208.67.222.222" "8.8.8.8" "1.1.1.1"; do ip=$(dig +short +time=2 +tries=1 @${ns} myip.opendns.com 2>/dev/null | grep -Eo '[0-9.]{7,15}' | head -n1); [ -n "$ip" ] && ! is_private_ip "$ip" && echo "$ip" && return; done; fi; if command -v curl >/dev/null 2>&1; then for api in "https://api4.ipify.org" "https://ifconfig.me/ip" "https://ip.sb" "https://icanhazip.com"; do ip=$(curl -4fsSL --max-time 4 "$api" 2>/dev/null | tr -d '\r' | grep -Eo '[0-9.]{7,15}' | head -n1); [ -n "$ip" ] && ! is_private_ip "$ip" && echo "$ip" && return; done; fi; }
if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP; else SIP=$(get_ssh_ip); PIP=$(get_pub_ip); echo " SSH IP: ${SIP:-无} / 公网IP: ${PIP:-无}"; if [ -z "$SIP" ] && [ -n "$PIP" ]; then SERVER_IP=$PIP; elif is_private_ip "$SIP" 2>/dev/null && [ -n "$PIP" ]; then SERVER_IP=$PIP; echo ">> NAT，切换公网 $PIP"; else SERVER_IP=${SIP:-$PIP}; fi; fi
[ -z "$SERVER_IP" ] && SERVER_IP="YOUR_PUBLIC_IP"
echo -e "${GREEN}========== V1.1 完成 ==========${PLAIN}"
echo -e "端口: ${CYAN}${HY_PORT}${PLAIN} 密码: ${CYAN}${HY_PASS}${PLAIN} IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo -e "hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Debian-Hy2-V1.1"
