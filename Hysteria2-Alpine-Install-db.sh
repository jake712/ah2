#!/bin/bash
# Hysteria 2 Debian V3.7 - NAT/Podman/LXC 低内存兼容 + IP检测修复版
# 基于 Alpine V3.7 jake712 移植
# 修复: V3.6 dig 语法反了 + curl ipv6超时

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

echo -e "${GREEN}=== Hysteria2 Debian V3.7 低内存/Podman修复版 ===${PLAIN}"
echo -e "容器ID: $(cat /etc/hostname 2>/dev/null || hostname) | 时间: $(date)"

# ===== [1/6] 基础依赖 - Debian 优化 =====
echo -e "${YELLOW}[1/6] 检查依赖 (Debian模式)...${PLAIN}"
echo -e "当前 resolv.conf:"
cat /etc/resolv.conf | head -n 5
cat /proc/meminfo 2>/dev/null | grep -E "MemTotal|MemAvailable" || free -m 2>/dev/null || true

if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "${YELLOW}检测到 Podman (dns.podman)，保留原有 DNS${PLAIN}"
else
  if [! -s /etc/resolv.conf ] ||! grep -q "nameserver" /etc/resolv.conf; then
    echo -e "${YELLOW}修复 DNS...${PLAIN}"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

APT_UPDATED=0
apt_update() {
  if [ $APT_UPDATED -eq 0 ]; then
    echo -e "${YELLOW}更新 apt 源...${PLAIN}"
    apt-get update -qq || apt-get update
    APT_UPDATED=1
  fi
}

ensure_cmd() {
  CMD=$1
  PKG=$2
  if! command -v "$CMD" >/dev/null 2>&1; then
    echo -e "${YELLOW}安装缺失: $CMD ($PKG)...${PLAIN}"
    apt_update
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$PKG" 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG" 2>&1 || echo -e "${RED}安装 $PKG 失败，尝试继续...${PLAIN}"
  else
    echo -e "已存在: $CMD"
  fi
}

if! command -v curl >/dev/null 2>&1 &&! command -v wget >/dev/null 2>&1; then
  apt_update
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl || apt-get install -y curl || true
fi

ensure_cmd openssl openssl
# Debian 12 用 bind9-dnsutils, 旧版用 dnsutils
if! command -v dig >/dev/null 2>&1; then
  apt_update
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bind9-dnsutils 2>/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils 2>/dev/null || apt-get install -y bind9-dnsutils
fi

if! command -v ss >/dev/null 2>&1; then
  ensure_cmd ss iproute2
fi

if [! -f /etc/ssl/certs/ca-certificates.crt ]; then
  ensure_cmd update-ca-certificates ca-certificates
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

if [ "$download_ok"!= "1" ] || [! -s /tmp/hysteria ]; then
  echo -e "${RED}下载失败，尝试备用镜像...${PLAIN}"
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    echo "尝试镜像 $mirror"
    curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
    wget -q --timeout=30 -O /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
  done
fi

if [! -s /tmp/hysteria ] || head -c 200 /tmp/hysteria 2>/dev/null | grep -qi "<html"; then
  echo -e "${RED}下载失败，请手动下载:${PLAIN}"
  echo -e "wget -O /usr/local/bin/hysteria $HY_URL"
  exit 1
fi

mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria
/usr/local/bin/hysteria version 2>&1 || /usr/local/bin/hysteria -v 2>&1 || echo "二进制已就绪"

# ===== [4/6] 生成证书和配置 =====
echo -e "${YELLOW}[4/6] 生成配置...${PLAIN}"
if [! -f /etc/hysteria/cert.crt ] || [! -f /etc/hysteria/key.key ]; then
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

# ===== [5/6] 服务 - Debian systemd =====
echo -e "${YELLOW}[5/6] 配置 systemd 服务...${PLAIN}"

cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria 2 Service (V3.7 Debian)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable hysteria >/dev/null 2>&1 || true
  systemctl restart hysteria || systemctl start hysteria
  sleep 2
  systemctl status hysteria --no-pager -l | head -n 30 || true
else
  echo -e "${YELLOW}未检测到 systemd，使用 nohup 后台运行...${PLAIN}"
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true
  sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
  sleep 2
fi

# 通用重启脚本
cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/bash
