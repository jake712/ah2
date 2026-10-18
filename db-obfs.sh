#!/bin/sh
# Hysteria 2 Debian V1.1 - NAT/Podman/LXC 高级防封锁增强版
# 适配: Debian 11/12/13, Ubuntu 20.04+, Karing 客户端完美适配版

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

while getopts "p:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 主端口] [-w 认证密码] [-i 公网IP]"; exit 0 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

echo -e "${GREEN}=== Hysteria2 Debian V1.1 Karing高强度防封锁版 ===${PLAIN}"
echo -e "容器ID: $(cat /etc/hostname 2>/dev/null || hostname) | 时间: $(date) | 系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2)"

# ===== [1/6] 基础依赖 - Debian适配 =====
echo -e "${YELLOW}[1/6] 检查依赖 (Debian低内存模式)...${PLAIN}"
export DEBIAN_FRONTEND=noninteractive

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
    apt-get install -y --no-install-recommends "$PKG" 2>&1 || apt-get install -y "$PKG" 2>&1 || echo -e "${RED}安装 $PKG 失败...${PLAIN}"
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

# ===== [2/6] 参数和路径 (新增: 随机混淆密码) =====
echo -e "${YELLOW}[2/6] 初始化参数...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-26169}

# 随机生成 Karing 所需的混淆密码 (obfs password)
if command -v openssl >/dev/null 2>&1; then
  HY_OBFS_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  [ -z "$CUSTOM_PASSWORD" ] && HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
else
  HY_OBFS_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
  [ -z "$CUSTOM_PASSWORD" ] && HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
fi
[ -n "$CUSTOM_PASSWORD" ] && HY_PASS=$CUSTOM_PASSWORD
[ -z "$HY_PASS" ] && HY_PASS="Hy2Pass$(date +%s | tail -c 4)"

# 端口跳跃范围设置 (主端口 + 额外1000个跳跃端口，防UDP单端口封锁)
HOPPING_START=$((HY_PORT + 1))
HOPPING_END=$((HY_PORT + 1000))
# 如果端口太大超过边界，换个安全范围
if [ $HOPPING_END -gt 65535 ]; then
  HOPPING_START=50000
  HOPPING_END=51000
fi

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
  if command -v curl >/dev/null 2>&1; then
    if curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL"; then download_ok=1; break; fi
  fi
  sleep 1
done

if [ "$download_ok" != "1" ]; then
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
  done
fi

if [ ! -s /tmp/hysteria ]; then echo -e "${RED}下载失败${PLAIN}"; exit 1; fi
mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

# ===== [4/6] 生成随机伪装证书和高级配置 =====
echo -e "${YELLOW}[4/6] 生成防封锁混淆配置...${PLAIN}"

# 伪装域名随机池，拒绝单一特征
DOMAINS="apple.com cloudflare.com icloud.com microsoft.com windows.com weather.com"
RANDOM_SNI=$(echo "$DOMAINS" | tr ' ' '\n' | shuf -n 1 2>/dev/null || echo "cloudflare.com")

if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=${RANDOM_SNI}" -days 3650 2>/dev/null
  chmod 600 /etc/hysteria/key.key
fi

# 写入带有 obfs 混淆与端口跳跃的全新配置文件
cat > /etc/hysteria/config.yaml <<EOF
# 监听主端口以及跳跃端口范围
listen: :${HY_PORT},:${HOPPING_START}-${HOPPING_END}

auth:
  type: password
  password: ${HY_PASS}

# 流量混淆配置 (Karing完美适配)
obfs:
  type: salamander
  salamander:
    password: ${HY_OBFS_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://${RANDOM_SNI}
    rewriteHost: true

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
EOF

# ===== [5/6] 服务 - Debian/Podman兼容 =====
echo -e "${YELLOW}[5/6] 配置并启动服务...${PLAIN}"

cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
pkill -f "hysteria.*config.yaml" || true
sleep 1
if systemctl is-active --quiet hysteria 2>/dev/null; then
  systemctl restart hysteria
else
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Server (Karing Enhanced)
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
  systemctl restart hysteria >/dev/null 2>&1 || true
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true
  sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi

# ===== [6/6] 获取公网 IP 并输出 Karing 专用配置 =====
echo -e "${YELLOW}[6/6] 生成 Karing 客户端配置信息...${PLAIN}"

SERVER_IP=$CUSTOM_IP
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 5 api.ipify.org || curl -4s --max-time 5 ifconfig.me || echo "你的服务器IP")
fi

echo -e "\n${GREEN}================================================"
echo -e "Hysteria 2 高强度防封锁节点部署成功！"
echo -e "================================================${PLAIN}"
echo -e "${CYAN}[Karing 客户端手动填入参数]:${PLAIN}"
echo -e "  - ${YELLOW}服务器地址 (Address):${PLAIN} ${SERVER_IP}"
echo -e "  - ${YELLOW}主端口 (Port):${PLAIN} ${HY_PORT}"
echo -e "  - ${YELLOW}端口跳跃 (Port Hopping):${PLAIN} ${HOPPING_START}-${HOPPING_END}"
echo -e "  - ${YELLOW}认证密码 (Password):${PLAIN} ${HY_PASS}"
echo -e "  - ${YELLOW}混淆类型 (Obfs Type):${PLAIN} salamander"
echo -e "  - ${YELLOW}混淆密码 (Obfs Password):${PLAIN} ${HY_OBFS_PASS}"
echo -e "  - ${YELLOW}SNI / 伪装域名:${PLAIN} ${RANDOM_SNI}"
echo -e "  - ${YELLOW}允许跳过证书验证 (Insecure):${PLAIN} 开启 (True) / 因为是自签证书"
echo -e "------------------------------------------------"
echo -e "${CYAN}[标准 Hysteria2 节点链接 (可尝试直接导入 Karing)]:${PLAIN}"
echo -e "  hy2://${HY_PASS}@${SERVER_IP}:${HY_PORT}?insecure=1&sni=${RANDOM_SNI}&obfs=salamander&obfs-password=${HY_OBFS_PASS}&mport=${HOPPING_START}-${HOPPING_END}"
echo -e "================================================"
