#!/bin/bash
# Hysteria2 Universal 完整版 V2.5 Final - Debian/Alpine 自選修復版
# 修復點: 所有 [! 和!= 前後都加了空格, 修復 config.yaml 截斷
# 用法: curl -fsSL https://raw.githubusercontent.com/jake712/ah2/main/Hysteria2-Alpine-Install-db.sh | bash -s -- -p 33950 -i 199.21.173.21 -o auto
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

CUSTOM_PORT=""; CUSTOM_PASSWORD=""; CUSTOM_IP=""; CUSTOM_OS="auto"
while getopts "p:w:i:o:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    o) CUSTOM_OS=$OPTARG ;;
    h) echo "用法: $0 [-o debian|alpine|auto] [-p 端口] [-w 密码] [-i 公网IP]"; exit 0 ;;
  esac
done

if [ "$(id -u)"!= "0" ]; then
  echo -e "${RED}请用 root 运行${PLAIN}"
  exit 1
fi

detect_os() {
  local OS_TYPE="unknown"
  if [ -f /etc/os-release ]; then
   . /etc/os-release
    case "$ID" in
      alpine) OS_TYPE="alpine" ;;
      debian|ubuntu) OS_TYPE="debian" ;;
    esac
    if [ "$OS_TYPE" = "unknown" ]; then
      case "$ID_LIKE" in
        *debian*|*ubuntu*) OS_TYPE="debian" ;;
        *alpine*) OS_TYPE="alpine" ;;
      esac
    fi
  fi
  if [ "$OS_TYPE" = "unknown" ]; then
    if command -v apk >/dev/null 2>&1; then OS_TYPE="alpine"; fi
    if command -v apt-get >/dev/null 2>&1; then OS_TYPE="debian"; fi
  fi
  echo "$OS_TYPE"
}

if [ "$CUSTOM_OS" = "debian" ] || [ "$CUSTOM_OS" = "ubuntu" ]; then
  FINAL_OS="debian"
elif [ "$CUSTOM_OS" = "alpine" ]; then
  FINAL_OS="alpine"
else
  DETECTED=$(detect_os)
  if [ "$DETECTED" = "unknown" ]; then FINAL_OS="debian"; else FINAL_OS="$DETECTED"; fi
fi

echo -e "${GREEN}=== Hysteria2 Universal V2.5 [${FINAL_OS}] ===${PLAIN}"
echo -e "容器ID: $(cat /etc/hostname 2>/dev/null || hostname) | 时间: $(date) | 系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2)"

APK_UPDATED=0; APT_UPDATED=0

install_deps_alpine() {
  echo -e "${YELLOW}[1/7] 检查依赖 (Alpine)...${PLAIN}"
  cat /etc/resolv.conf | head -n 5
  if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
    echo -e "${YELLOW}检测到 Podman，保留原有 DNS${PLAIN}"
  else
    if [! -s /etc/resolv.conf ] ||! grep -q "nameserver" /etc/resolv.conf; then
      echo "nameserver 1.1.1.1" > /etc/resolv.conf
      echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    fi
  fi
  if [ "$APK_UPDATED" -eq 0 ]; then apk update; APK_UPDATED=1; fi
  if! command -v curl >/dev/null 2>&1 &&! command -v wget >/dev/null 2>&1; then apk add --no-cache curl; fi
  apk add --no-cache openssl bind-tools iproute2 procps ca-certificates python3 || true
}

install_deps_debian() {
  echo -e "${YELLOW}[1/7] 检查依赖 (Debian)...${PLAIN}"
  export DEBIAN_FRONTEND=noninteractive
  if [ "$APT_UPDATED" -eq 0 ]; then apt-get update -y; APT_UPDATED=1; fi
  apt-get install -y curl wget openssl bind9-dnsutils iproute2 procps ca-certificates python3 cron || apt-get install -y curl wget openssl iproute2 procps ca-certificates python3 || true
}

echo -e "${YELLOW}[2/7] 初始化参数...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-33950}
if [ -n "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$CUSTOM_PASSWORD
else
  HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  if [ -z "$HY_PASS" ]; then HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16); fi
fi
if [ -z "$HY_PASS" ]; then HY_PASS="Hy2$(date +%s | tail -c 8)"; fi
ARCH=$(uname -m)
case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log
chmod 700 /etc/hysteria 2>/dev/null || true

if [ "$FINAL_OS" = "alpine" ]; then install_deps_alpine; else install_deps_debian; fi

echo -e "${YELLOW}[3/7] 下载 Hysteria2 $HY_ARCH...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
download_ok=0
for i in 1 2 3; do
  if command -v curl >/dev/null 2>&1; then curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" && download_ok=1 && break; fi
  if command -v wget >/dev/null 2>&1; then wget -q --timeout=30 -O /tmp/hysteria "$HY_URL" && download_ok=1 && break; fi
  sleep 1
done
if [ "$download_ok"!= "1" ] || [! -s /tmp/hysteria ]; then
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
    wget -q --timeout=30 -O /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
  done
fi
if [! -s /tmp/hysteria ]; then echo -e "${RED}下载失败${PLAIN}"; exit 1; fi
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria
/usr/local/bin/hysteria version || true

echo -e "${YELLOW}[4/7] 生成配置...${PLAIN}"
if [! -f /etc/hysteria/cert.crt ] || [! -f /etc/hysteria/key.key ]; then
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

echo -e "${YELLOW}[5/7] 配置服务 [${FINAL_OS}]...${PLAIN}"
cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q hysteria; then
  systemctl restart hysteria; echo "systemd 重启完成"
elif command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/hysteria ]; then
  rc-service hysteria restart; echo "OpenRC 重启完成"
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 & echo "nohup 重启完成"
fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh

if [ "$FINAL_OS" = "alpine" ]; then
  cat > /etc/init.d/hysteria <<'INIT'
#!/sbin/openrc-run
name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria/hysteria.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
depend() { need net; }
start_pre() { checkpath --directory --mode 0755 /run/hysteria; checkpath --file --mode 0644 /var/log/hysteria.log; }
INIT
  chmod +x /etc/init.d/hysteria
  if command -v rc-service >/dev/null 2>&1; then rc-update add hysteria default 2>/dev/null || true; rc-service hysteria restart || rc-service hysteria start || true
  else pkill -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1; nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
  fi
else
  cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Server V2.5 Universal
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
  systemctl daemon-reload; systemctl enable hysteria 2>/dev/null || true; systemctl restart hysteria || true
fi

ss -tulpn 2>/dev/null | grep -E "$HY_PORT|hysteria" || true
tail -n 10 /var/log/hysteria.log 2>/dev/null || journalctl -u hysteria -n 10 --no-pager 2>/dev/null || true

# ===== [6/7] IP檢測 V3.7 =====
echo -e "${YELLOW}[6/7] IP检测...${PLAIN}"
is_private_ip() {
  case "$1" in 10.*|192.168.*|127.*|172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*|0.0.0.0) return 0;; esac
  return 1
}
get_pub_ip() {
  curl -4fsSL --max-time 4 https://api4.ipify.org 2>/dev/null || curl -4fsSL --max-time 4 https://ifconfig.me 2>/dev/null || wget -qO- --timeout=4 https://api4.ipify.org 2>/dev/null || echo ""
}
if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP; else SERVER_IP=$(get_pub_ip); fi
if [ -z "$SERVER_IP" ]; then SERVER_IP="YOUR_PUBLIC_IP"; fi

echo -e "${YELLOW}[7/7] 生成证书pin...${PLAIN}"
CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary 2>/dev/null | openssl enc -base64 2>/dev/null | tr -d '\n')
if [ -z "$CERT_PIN" ]; then CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout 2>/dev/null | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary 2>/dev/null | openssl enc -base64 2>/dev/null | tr -d '\n'); fi
CERT_PIN_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$CERT_PIN" 2>/dev/null || echo "$CERT_PIN")

echo -e "${GREEN}========== V2.5 完成 [${FINAL_OS}] ==========${PLAIN}"
echo -e "端口: ${CYAN}${HY_PORT}${PLAIN} | 密码: ${CYAN}${HY_PASS}${PLAIN} | IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo -e "pin: ${CYAN}${CERT_PIN}${PLAIN}"
echo -e ""
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2-Insecure${PLAIN}"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_PIN_ENC}#Hy2-Pin${PLAIN}"
echo -e ""
echo -e "管理: /usr/local/bin/hy2-restart.sh"
