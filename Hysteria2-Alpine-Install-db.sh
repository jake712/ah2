#!/bin/sh
# Hysteria 2 Debian V1.1 - NAT/Podman/LXC 低内存兼容 + IP检测修复版 + 证书pin版
# 基于 jake712 V1.0 修改
# 适配: Debian 11/12/13, Ubuntu 20.04+, Podman无systemd容器

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

echo -e "${GREEN}=== Hysteria2 Debian V1.1 Podman+Cert版 ===${PLAIN}"
echo -e "容器ID: $(cat /etc/hostname 2>/dev/null || hostname) | 时间: $(date) | 系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2)"

# ===== [1/6] 基础依赖 - Debian适配 =====
echo -e "${YELLOW}[1/6] 检查依赖 (Debian低内存模式)...${PLAIN}"
export DEBIAN_FRONTEND=noninteractive
echo -e "当前 resolv.conf:"
cat /etc/resolv.conf | head -n 5
cat /proc/meminfo 2>/dev/null | grep -E "MemTotal|MemAvailable" || free -m 2>/dev/null || true

if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "${YELLOW}检测到 Podman (dns.podman)，保留原有 DNS${PLAIN}"
else
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo -e "${YELLOW}修复 DNS...${PLAIN}"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo -e "${RED}未检测到 apt-get，不是 Debian/Ubuntu 系统${PLAIN}"; exit 1
fi

APT_UPDATED=0
apt_update() {
  if [ $APT_UPDATED -eq 0 ]; then
    echo -e "${YELLOW}apt-get update...${PLAIN}"
    apt-get update -qq
    APT_UPDATED=1
  fi
}

ensure_cmd() {
  CMD=$1
  PKG=$2
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo -e "${YELLOW}安装缺失: $CMD ($PKG)...${PLAIN}"
    apt_update
    apt-get install -y --no-install-recommends "$PKG" 2>&1 || apt-get install -y "$PKG" 2>&1 || echo -e "${RED}安装 $PKG 失败，尝试继续...${PLAIN}"
  else
    echo -e "已存在: $CMD"
  fi
}

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  apt_update
  apt-get install -y --no-install-recommends curl 2>&1 || apt-get install -y curl || true
fi

ensure_cmd openssl openssl
ensure_cmd dig dnsutils
if ! command -v ss >/dev/null 2>&1; then
  apt_update
  apt-get install -y --no-install-recommends iproute2 2>&1 || true
fi
if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
  apt_update
  apt-get install -y --no-install-recommends ca-certificates 2>&1 || true
  update-ca-certificates 2>/dev/null || true
fi

# ===== [2/6] 参数和路径 =====
echo -e "${YELLOW}[2/6] 初始化参数...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-26169}
if [ -n "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$CUSTOM_PASSWORD
else
  if command -v openssl >/dev/null 2>&1; then
    HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  else
    HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
  fi
fi
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  armv7l|arm) HY_ARCH="arm" ;;
  *) HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log
chmod 700 /etc/hysteria 2>/dev/null || true

# ===== [3/6] 下载 Hysteria2 =====
echo -e "${YELLOW}[3/6] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
download_ok=0
for i in 1 2 3; do
  echo "尝试下载 $HY_URL (第 $i 次)"
  if command -v curl >/dev/null 2>&1; then
    if curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL"; then download_ok=1; break; fi
  fi
  if command -v wget >/dev/null 2>&1; then
    if wget -q --timeout=30 -O /tmp/hysteria "$HY_URL"; then download_ok=1; break; fi
  fi
  sleep 1
done

if [ "$download_ok" != "1" ] || [ ! -s /tmp/hysteria ]; then
  echo -e "${RED}下载失败，尝试备用镜像...${PLAIN}"
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    echo "尝试镜像 $mirror"
    curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
    wget -q --timeout=30 -O /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
  done
fi

if [ ! -s /tmp/hysteria ] || head -c 200 /tmp/hysteria 2>/dev/null | grep -qi "<html"; then
  echo -e "${RED}下载失败，请手动下载:${PLAIN}"
  echo -e "wget -O /usr/local/bin/hysteria $HY_URL"
  exit 1
fi

mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria
/usr/local/bin/hysteria version 2>&1 || /usr/local/bin/hysteria -v 2>&1 || echo "二进制已就绪"

# ===== [4/6] 生成证书和配置 =====
echo -e "${YELLOW}[4/6] 生成配置...${PLAIN}"
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

# ===== [5/6] 服务 - Debian/Podman兼容 =====
echo -e "${YELLOW}[5/6] 配置服务...${PLAIN}"

cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
pkill -f "hysteria.*config.yaml" || true
sleep 1
if systemctl is-active --quiet hysteria 2>/dev/null; then
  systemctl restart hysteria
else
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
echo "已重启，日志: tail -f /var/log/hysteria.log"
RESTART
chmod +x /usr/local/bin/hy2-restart.sh

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  echo -e "${GREEN}检测到 systemd，使用 systemd 服务${PLAIN}"
  cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Server (Debian Podman Fix)
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
  systemctl daemon-reload
  systemctl enable hysteria >/dev/null 2>&1 || true
  systemctl restart hysteria 2>&1 || systemctl start hysteria 2>&1 || true
  sleep 2
else
  echo -e "${YELLOW}未检测到 systemd (Podman容器常见)，使用 nohup 后台运行...${PLAIN}"
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true
  sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
  sleep 2
fi

sleep 1
if command -v ss >/dev/null 2>&1; then
  ss -tulpn 2>/dev/null | grep -E "$HY_PORT|hysteria" || true
fi
tail -n 20 /var/log/hysteria.log 2>/dev/null || true

# ===== [6/6] IP检测 V3.7 修复版 =====
echo -e "${YELLOW}[6/6] IP检测 V3.7 修复...${PLAIN}"

is_private_ip() {
  local ip=$1
  [ -z "$ip" ] && return 0
  case "$ip" in
    0.0.0.0|10.*|192.168.*|127.*|169.254.*) return 0 ;;
    172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;;
  esac
  if echo "$ip" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.'; then return 0; fi
  return 1
}

get_ssh_ip() {
  if [ -n "$SSH_CONNECTION" ]; then echo "$SSH_CONNECTION" | awk '{print $3}'; return; fi
  if [ -d /proc ]; then
    for f in /proc/[0-9]*/environ; do
      [ -f "$f" ] || continue
      ip=$(tr '\0' '\n' < "$f" 2>/dev/null | grep '^SSH_CONNECTION=' | cut -d= -f2 | awk '{print $3}' | tail -n1)
      if echo "$ip" | grep -Eq '^[0-9.]+$' && [ -n "$ip" ]; then echo "$ip"; return; fi
    done
  fi
  ss -tn 2>/dev/null | grep ':22' | awk '{print $4}' | cut -d: -f1 | grep -E '^[0-9.]+$' | grep -v '^127\.' | head -n1
}

get_pub_ip() {
  local ip
  if command -v dig >/dev/null 2>&1; then
    for ns in "208.67.222.222" "208.67.220.220" "8.8.8.8" "1.1.1.1"; do
      ip=$(dig +short +time=2 +tries=1 @${ns} myip.opendns.com 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
      if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi
    done
    ip=$(dig +short +time=2 +tries=1 @8.8.8.8 TXT o-o.myaddr.l.google.com 2>/dev/null | tr -d '"' | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
    if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi
  fi
  if command -v curl >/dev/null 2>&1; then
    for api in "https://api4.ipify.org" "https://ifconfig.me/ip" "https://ip.sb" "http://api.ipify.org" "https://icanhazip.com" "https://checkip.amazonaws.com"; do
      ip=$(curl -4fsSL --max-time 4 "$api" 2>/dev/null | tr -d '\r' | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
      if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi
    done
  fi
  if command -v wget >/dev/null 2>&1; then
    for api in "https://api4.ipify.org" "https://ifconfig.me" "http://icanhazip.com"; do
      ip=$(wget -qO- --timeout=4 "$api" 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
      if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi
    done
  fi
}

if [ -n "$CUSTOM_IP" ]; then
  SERVER_IP=$CUSTOM_IP
  echo -e "${GREEN}手动指定 -i: $SERVER_IP${PLAIN}"
else
  SIP=$(get_ssh_ip)
  PIP=$(get_pub_ip)
  echo -e " SSH会话IP: ${YELLOW}${SIP:-未找到}${PLAIN}"
  echo -e " 出口公网IP: ${YELLOW}${PIP:-未知}${PLAIN}"
  echo -e " SSH_CONNECTION=${SSH_CONNECTION:-空}"

  if [ -z "$SIP" ] && [ -n "$PIP" ]; then
    SERVER_IP=$PIP
    echo -e "${GREEN}>> 采用出口公网IP: $SERVER_IP${PLAIN}"
  elif [ -z "$SIP" ] && [ -z "$PIP" ]; then
    SERVER_IP=""
    echo -e "${RED}>> 无法自动获取任何IP${PLAIN}"
  elif is_private_ip "$SIP"; then
    if [ -n "$PIP" ]; then
      SERVER_IP=$PIP
      echo -e "${YELLOW}>> SSH IP $SIP 是内网 (NAT/Podman)，切换到公网IP: $SERVER_IP${PLAIN}"
    else
      SERVER_IP=$SIP
      echo -e "${RED}>> 内网IP $SIP，但出口IP获取失败，请用 -i 指定${PLAIN}"
    fi
  else
    SERVER_IP=$SIP
    echo -e "${GREEN}>> 采用公网IP: $SERVER_IP${PLAIN}"
  fi
fi

if [ -z "$SERVER_IP" ]; then
  echo -e ""
  echo -e "${RED}========== 获取IP失败 ==========${PLAIN}"
  echo -e "在 Podman/NAT 容器中，请在宿主机执行: curl -s https://api4.ipify.org"
  echo -e "然后重新安装: bash $0 -p $HY_PORT -i 你的公网IP"
  SERVER_IP="YOUR_PUBLIC_IP"
fi

# ===== [7/7] 新增：证书处理与客户端配置 =====
echo -e "${YELLOW}[7/7] 生成证书pin与客户端配置...${PLAIN}"

# 计算 pinSHA256 (Hysteria官方推荐方式)
CERT_PIN=""
if [ -f /etc/hysteria/cert.crt ]; then
  if openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary 2>/dev/null | openssl enc -base64 2>/dev/null > /tmp/pin.tmp; then
    CERT_PIN=$(cat /tmp/pin.tmp | tr -d '\n')
  else
    # 兼容旧版 openssl
    CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout 2>/dev/null | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary 2>/dev/null | openssl enc -base64 2>/dev/null | tr -d '\n')
  fi
  rm -f /tmp/pin.tmp
fi

# 提取证书信息
CERT_DATES=$(openssl x509 -in /etc/hysteria/cert.crt -noout -dates 2>/dev/null | tr '\n' ' ')
CERT_FINGERPRINT=$(openssl x509 -in /etc/hysteria/cert.crt -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)

# 生成客户端YAML (更安全的方式)
cat > /root/hy2-client.yaml <<EOF
server: ${SERVER_IP}:${HY_PORT}
auth: ${HY_PASS}
tls:
  sni: bing.com
  pinSHA256: ${CERT_PIN}
  # 如果 pin 失效，回退用 insecure
  # insecure: true
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080
EOF

# 备份证书到 root 方便下载
cp /etc/hysteria/cert.crt /root/hy2-cert.crt
cp /etc/hysteria/cert.crt /etc/hysteria/client.crt
chmod 644 /root/hy2-cert.crt /etc/hysteria/client.crt

echo ""
echo -e "${GREEN}========== Debian V1.1 完成 (证书增强版) ==========${PLAIN}"
echo -e "端口: ${CYAN}${HY_PORT}${PLAIN}"
echo -e "密码: ${CYAN}${HY_PASS}${PLAIN}"
echo -e "IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo -e "证书: ${CYAN}/etc/hysteria/cert.crt${PLAIN}"
echo -e "指纹: ${CYAN}${CERT_FINGERPRINT}${PLAIN}"
echo -e "pinSHA256: ${CYAN}${CERT_PIN}${PLAIN}"
echo -e "有效期: ${CYAN}${CERT_DATES}${PLAIN}"
echo -e ""
echo -e "${YELLOW}--- 客户端配置已生成: /root/hy2-client.yaml ---${PLAIN}"
cat /root/hy2-client.yaml
echo -e ""
echo -e "${GREEN}--- 分享链接 (推荐-安全) ---${PLAIN}"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_PIN}#Debian-Hy2-V1.1-Pin${PLAIN}"
echo -e ""
echo -e "${YELLOW}--- 分享链接 (兼容-需insecure) ---${PLAIN}"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Debian-Hy2-V1.1-Insecure${PLAIN}"
echo -e ""
echo -e "${CYAN}--- 证书内容 (可供客户端手动导入) ---${PLAIN}"
cat /etc/hysteria/cert.crt
echo -e ""
echo -e "日志: tail -f /var/log/hysteria.log"
echo -e "重启: /usr/local/bin/hy2-restart.sh 或 systemctl restart hysteria"
echo -e "客户端配置: cat /root/hy2-client.yaml"
echo -e "下载证书: cat /root/hy2-cert.crt"
echo -e "记得放行 UDP ${CYAN}${HY_PORT}${PLAIN}"
if [ "$SERVER_IP" = "YOUR_PUBLIC_IP" ]; then
  echo -e "${RED}注意: 请替换 YOUR_PUBLIC_IP 为真实公网IP${PLAIN}"
fi
