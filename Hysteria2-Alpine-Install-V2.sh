#!/bin/sh
# Hysteria 2 Alpine V1.2 - Podman/LXC/NAT + 证书pin + Karing修复完整版
# 基于 Debian V1.2 移植 - Alpine 3.18+ / OpenRC
# 适配: Alpine, Podman无systemd容器

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

echo -e "${GREEN}=== Hysteria2 Alpine V1.2 Karing修复版 ===${PLAIN}"
echo -e "容器ID: $(cat /etc/hostname 2>/dev/null || hostname) | 时间: $(date) | 系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2)"

# ===== [1/7] 基础依赖 =====
echo -e "${YELLOW}[1/7] 检查依赖 (Alpine低内存模式)...${PLAIN}"
cat /etc/resolv.conf | head -n 5
cat /proc/meminfo 2>/dev/null | grep -E "MemTotal|MemAvailable" || free -m 2>/dev/null || true

if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "${YELLOW}检测到 Podman (dns.podman)，保留原有 DNS${PLAIN}"
else
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

if ! command -v apk >/dev/null 2>&1; then echo -e "${RED}未检测到 apk，请确认是 Alpine 系统${PLAIN}"; exit 1; fi

APK_UPDATED=0
apk_update() {
  if [ $APK_UPDATED -eq 0 ]; then echo -e "${YELLOW}apk update...${PLAIN}"; apk update; APK_UPDATED=1; fi
}
ensure_cmd() {
  CMD=$1; PKG=$2
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo -e "${YELLOW}安装缺失: $CMD ($PKG)...${PLAIN}"
    apk_update; apk add --no-cache "$PKG" 2>&1 || true
  else echo -e "已存在: $CMD"; fi
}

# Alpine 包名映射
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then apk_update; apk add --no-cache curl || true; fi
ensure_cmd openssl openssl
ensure_cmd dig bind-tools
ensure_cmd ss iproute2
ensure_cmd pkill procps

if [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -f /etc/ssl/certs/ca-bundle.crt ]; then
  apk_update; apk add --no-cache ca-certificates 2>&1 || true; update-ca-certificates 2>/dev/null || true
fi

# ===== [2/7] 参数 =====
echo -e "${YELLOW}[2/7] 初始化参数...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-26169}
if [ -n "$CUSTOM_PASSWORD" ]; then HY_PASS=$CUSTOM_PASSWORD
else
  if command -v openssl >/dev/null 2>&1; then HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  else HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16); fi
fi
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"

ARCH=$(uname -m)
case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; armv7l|arm) HY_ARCH="arm";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log
chmod 700 /etc/hysteria 2>/dev/null || true

# ===== [3/7] 下载 =====
echo -e "${YELLOW}[3/7] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
download_ok=0
for i in 1 2 3; do
  echo "尝试下载 $HY_URL (第 $i 次)"
  if command -v curl >/dev/null 2>&1; then curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" && download_ok=1 && break; fi
  if command -v wget >/dev/null 2>&1; then wget -q --timeout=30 -O /tmp/hysteria "$HY_URL" && download_ok=1 && break; fi
  sleep 1
done
if [ "$download_ok" != "1" ] || [ ! -s /tmp/hysteria ]; then
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    echo "尝试镜像 $mirror"
    curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
    wget -q --timeout=30 -O /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
  done
fi
if [ ! -s /tmp/hysteria ] || head -c 200 /tmp/hysteria 2>/dev/null | grep -qi "<html"; then echo -e "${RED}下载失败${PLAIN}"; exit 1; fi
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria
/usr/local/bin/hysteria version 2>&1 || true

# ===== [4/7] 证书和配置 =====
echo -e "${YELLOW}[4/7] 生成配置...${PLAIN}"
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || \
  openssl genpkey -algorithm EC -pkeyopt ec_param_enc:named_curve -pkeyopt ec_paramgen_curve:P-256 -out /etc/hysteria/key.key 2>/dev/null || \
  openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650 2>/dev/null || \
  openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
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
cat /etc/hysteria/config.yaml

# ===== [5/7] 服务 (Alpine OpenRC) =====
echo -e "${YELLOW}[5/7] 配置服务 (Alpine OpenRC)...${PLAIN}"

# OpenRC init 脚本
cat > /etc/init.d/hysteria <<'INIT'
#!/sbin/openrc-run
name="hysteria"
description="Hysteria2 Server V1.2 Alpine"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria/hysteria.pid"
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
INIT
chmod +x /etc/init.d/hysteria

# 重启脚本 (兼容 OpenRC 和 无服务管理器)
cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/hysteria ]; then
  rc-service hysteria restart
else
  pkill -f "hysteria.*config.yaml" || true
  sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
echo "已重启，日志: tail -f /var/log/hysteria.log"
RESTART
chmod +x /usr/local/bin/hy2-restart.sh

# 启动
if [ -f /sbin/openrc-run ] || command -v rc-service >/dev/null 2>&1; then
  rc-update add hysteria default 2>/dev/null || true
  rc-service hysteria restart 2>&1 || rc-service hysteria start 2>&1 || /etc/init.d/hysteria restart 2>&1 || true
  sleep 2
else
  # Podman容器没有OpenRC的情况
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 & sleep 2
fi

ss -tulpn 2>/dev/null | grep -E "$HY_PORT|hysteria" || ss -tulnp 2>/dev/null | grep -E "$HY_PORT|hysteria" || netstat -tulpn 2>/dev/null | grep "$HY_PORT" || true
tail -n 10 /var/log/hysteria.log 2>/dev/null || true

# ===== [6/7] IP检测 V3.7 =====
echo -e "${YELLOW}[6/7] IP检测...${PLAIN}"
is_private_ip() {
  local ip=$1; [ -z "$ip" ] && return 0
  case "$ip" in 0.0.0.0|10.*|192.168.*|127.*|169.254.*) return 0;; 172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0;; esac
  if echo "$ip" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.'; then return 0; fi; return 1
}
get_ssh_ip() {
  if [ -n "$SSH_CONNECTION" ]; then echo "$SSH_CONNECTION" | awk '{print $3}'; return; fi
  if [ -d /proc ]; then for f in /proc/[0-9]*/environ; do [ -f "$f" ] || continue; ip=$(tr '\0' '\n' < "$f" 2>/dev/null | grep '^SSH_CONNECTION=' | cut -d= -f2 | awk '{print $3}' | tail -n1); if echo "$ip" | grep -Eq '^[0-9.]+$' && [ -n "$ip" ]; then echo "$ip"; return; fi; done; fi
  ss -tn 2>/dev/null | grep ':22' | awk '{print $4}' | cut -d: -f1 | grep -E '^[0-9.]+$' | grep -v '^127\.' | head -n1
}
get_pub_ip() {
  local ip
  if command -v dig >/dev/null 2>&1; then for ns in "208.67.222.222" "8.8.8.8" "1.1.1.1"; do ip=$(dig +short +time=2 +tries=1 @${ns} myip.opendns.com 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1); if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi; done; fi
  if command -v curl >/dev/null 2>&1; then for api in "https://api4.ipify.org" "https://ifconfig.me/ip" "https://ip.sb" "https://icanhazip.com"; do ip=$(curl -4fsSL --max-time 4 "$api" 2>/dev/null | tr -d '\r' | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1); if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi; done; fi
  if command -v wget >/dev/null 2>&1; then for api in "https://api4.ipify.org" "https://ifconfig.me"; do ip=$(wget -qO- --timeout=4 "$api" 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1); if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi; done; fi
}
if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP; echo -e "${GREEN}手动指定 -i: $SERVER_IP${PLAIN}"
else
  SIP=$(get_ssh_ip); PIP=$(get_pub_ip)
  echo -e " SSH会话IP: ${YELLOW}${SIP:-未找到}${PLAIN} | 出口公网IP: ${YELLOW}${PIP:-未知}${PLAIN}"
  if [ -z "$SIP" ] && [ -n "$PIP" ]; then SERVER_IP=$PIP
  elif [ -z "$SIP" ] && [ -z "$PIP" ]; then SERVER_IP=""
  elif is_private_ip "$SIP"; then if [ -n "$PIP" ]; then SERVER_IP=$PIP; else SERVER_IP=$SIP; fi
  else SERVER_IP=$SIP; fi
fi
if [ -z "$SERVER_IP" ]; then echo -e "${RED}无法获取IP，请用 -i 指定${PLAIN}"; SERVER_IP="YOUR_PUBLIC_IP"; fi

# ===== [7/7] 证书pin + Karing修复 + 客户端配置 =====
echo -e "${YELLOW}[7/7] 生成证书pin与客户端配置 (Karing修复)...${PLAIN}"

urlencode() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
  else
    printf '%s' "$1" | sed -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g' -e 's/:/%3A/g'
  fi
}

CERT_PIN=""; CERT_PIN_ENC=""; CERT_FPR=""; CERT_DATES=""
if [ -f /etc/hysteria/cert.crt ]; then
  if openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary 2>/dev/null | openssl enc -base64 2>/dev/null > /tmp/pin.tmp; then
    CERT_PIN=$(cat /tmp/pin.tmp | tr -d '\n')
  else
    CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout 2>/dev/null | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary 2>/dev/null | openssl enc -base64 2>/dev/null | tr -d '\n')
  fi
  rm -f /tmp/pin.tmp
  CERT_PIN_ENC=$(urlencode "$CERT_PIN")
  CERT_FPR=$(openssl x509 -in /etc/hysteria/cert.crt -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
  CERT_DATES=$(openssl x509 -in /etc/hysteria/cert.crt -noout -dates 2>/dev/null | tr '\n' ' ')
fi

cp /etc/hysteria/cert.crt /root/hy2-cert.crt 2>/dev/null || true
cp /etc/hysteria/cert.crt /etc/hysteria/client.crt 2>/dev/null || true
chmod 644 /root/hy2-cert.crt 2>/dev/null || true

cat > /root/hy2-client.yaml <<EOF
server: ${SERVER_IP}:${HY_PORT}
auth: ${HY_PASS}
tls:
  sni: bing.com
  pinSHA256: ${CERT_PIN}
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080
EOF

cat > /root/hy2-clash.yaml <<EOF
# Karing / Clash.Meta / Mihomo 专用 - 直接导入
proxies:
    - name: Hy2-${SERVER_IP}
    type: hysteria2
    server: ${SERVER_IP}
    port: ${HY_PORT}
    password: ${HY_PASS}
    sni: bing.com
    skip-cert-verify: false
    pinSHA256: ${CERT_PIN}
    # 如果上面在你的Karing版本报错，注释掉上面两行，启用下面两行
    # skip-cert-verify: true
    # fingerprint: chrome
EOF

cat > /root/hy2-singbox.json <<EOF
{
  "type": "hysteria2",
  "tag": "Hy2-${SERVER_IP}",
  "server": "${SERVER_IP}",
  "server_port": ${HY_PORT},
  "password": "${HY_PASS}",
  "tls": {
    "enabled": true,
    "server_name": "bing.com",
    "pinSHA256": "${CERT_PIN}",
    "insecure": false,
    "alpn": "h3"
  }
}
EOF

echo ""
echo -e "${GREEN}========== Alpine V1.2 完成 (Karing修复版) ==========${PLAIN}"
echo -e "端口: ${CYAN}${HY_PORT}${PLAIN} | 密码: ${CYAN}${HY_PASS}${PLAIN} | IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo -e "证书指纹: ${CYAN}${CERT_FPR}${PLAIN}"
echo -e "pin原始: ${CYAN}${CERT_PIN}${PLAIN}"
echo -e "pin编码: ${CYAN}${CERT_PIN_ENC}${PLAIN}"
echo -e ""
echo -e "${GREEN}--- [Karing/Clash专用-推荐] 分享链接 (URL编码后) ---${PLAIN}"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_PIN_ENC}#Hy2-Karing-Pin${PLAIN}"
echo -e ""
echo -e "${YELLOW}--- [Karing兼容-带insecure] 如果上面还不行用这个 ---${PLAIN}"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1&pinSHA256=${CERT_PIN_ENC}#Hy2-Karing-InsecurePin${PLAIN}"
echo -e ""
echo -e "${YELLOW}--- [通用兼容] 分享链接 (insecure) ---${PLAIN}"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2-Insecure${PLAIN}"
echo -e ""
echo -e "${CYAN}--- Clash YAML (Karing最稳) 路径: /root/hy2-clash.yaml ---${PLAIN}"
cat /root/hy2-clash.yaml
echo -e ""
echo -e "${CYAN}--- 证书内容 ---${PLAIN}"
cat /etc/hysteria/cert.crt
echo -e ""
echo -e "管理命令:"
echo -e "  日志: tail -f /var/log/hysteria.log"
echo -e "  重启: rc-service hysteria restart  或  /usr/local/bin/hy2-restart.sh"
echo -e "  开机自启: rc-update add hysteria default"
echo -e "  客户端: cat /root/hy2-client.yaml"
echo -e "  Clash: cat /root/hy2-clash.yaml"
echo -e "  JSON: cat /root/hy2-singbox.json"
echo -e "  证书: cat /root/hy2-cert.crt"
echo -e "  放行: UDP ${HY_PORT}"
