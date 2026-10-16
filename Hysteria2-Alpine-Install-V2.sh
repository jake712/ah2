#!/bin/bash
# Hysteria2 Universal V1.4.2 完整修復版 - Debian & Alpine 自選
# 修復: [ "$(id -u)"!=, [!, config.yaml 截斷
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

if [ "$(id -u)"!= "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

echo -e "${GREEN}=== Hysteria2 V1.4.2 完整修复版 [${CUSTOM_OS}] ===${PLAIN}"

# ===== [1/7] 系统判断 + 依赖 =====
if command -v apk >/dev/null 2>&1 || [ "$CUSTOM_OS" = "alpine" ]; then
  echo -e "${YELLOW}[Alpine] 安装依赖...${PLAIN}"
  apk update
  apk add --no-cache curl wget openssl ca-certificates iproute2 python3 bind-tools procps dcron
  rc-update add dcron default 2>/dev/null || true
  service dcron start 2>/dev/null || true
  FINAL_OS="alpine"
else
  echo -e "${YELLOW}[Debian] 安装依赖...${PLAIN}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends curl wget openssl ca-certificates iproute2 python3 dnsutils cron procps 2>&1 | tail -n 3 || true
  FINAL_OS="debian"
fi

# ===== [2/7] 参数 =====
HY_PORT=${CUSTOM_PORT:-33950}
if [ -n "$CUSTOM_PASSWORD" ]; then HY_PASS=$CUSTOM_PASSWORD
else HY_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16); fi
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"

ARCH=$(uname -m)
case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /var/log
chmod 700 /etc/hysteria 2>/dev/null || true

# ===== [3/7] 下载 =====
echo -e "${YELLOW}下载 Hysteria2 $HY_ARCH...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" || wget -q -O /tmp/hysteria "$HY_URL" || true
if [! -s /tmp/hysteria ]; then echo -e "${RED}下载失败${PLAIN}"; exit 1; fi
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria
/usr/local/bin/hysteria version || true

# ===== [4/7] 证书和配置 =====
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
cat /etc/hysteria/config.yaml

# ===== [5/7] 服务 =====
cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet hysteria 2>/dev/null; then
  systemctl restart hysteria; echo "systemd已重启"
else
  pkill -9 -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1
  setsid nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 & sleep 1
  ss -unlp | grep hysteria || true
fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh

IS_SYSTEMD=0
[ -d /run/systemd/system ] && [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ] && IS_SYSTEMD=1

if [ "$IS_SYSTEMD" = "1" ]; then
  cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Server V1.4.2
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
  systemctl daemon-reload
  systemctl enable hysteria 2>/dev/null || true
  systemctl restart hysteria 2>/dev/null || systemctl start hysteria 2>/dev/null || true
else
  pkill -9 -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1
  setsid nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
  (crontab -l 2>/dev/null | grep -v "hysteria server"; echo "@reboot sleep 15 && setsid nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1"; echo "*/2 * * * * pgrep -f 'hysteria.*config.yaml' >/dev/null || setsid nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1") | crontab - 2>/dev/null || true
fi

iptables -C INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || true
ss -unlp | grep -E "${HY_PORT}|hysteria" || true
tail -n 20 /var/log/hysteria.log 2>/dev/null || journalctl -u hysteria -n 20 --no-pager 2>/dev/null || true

# ===== [6/7] IP =====
SERVER_IP=${CUSTOM_IP:-199.21.173.21}
[ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "199.21.173.21" ] && SERVER_IP=$(curl -4fsSL https://api4.ipify.org 2>/dev/null || curl -4fsSL https://ifconfig.me 2>/dev/null || echo "YOUR_PUBLIC_IP")
[ -z "$SERVER_IP" ] && SERVER_IP="YOUR_PUBLIC_IP"

# ===== [7/7] Pin =====
CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')
[ -z "$CERT_PIN" ] && CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout | openssl rsa -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')
CERT_PIN_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$CERT_PIN" 2>/dev/null || echo "$CERT_PIN")

echo -e "${GREEN}========== V1.4.2 完成 [${FINAL_OS}] ==========${PLAIN}"
echo -e "端口: ${CYAN}${HY_PORT}${PLAIN} | 密码: ${CYAN}${HY_PASS}${PLAIN} | IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo -e "pin: ${CYAN}${CERT_PIN}${PLAIN}"
echo -e ""
echo -e "${GREEN}1. hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2-Insecure${PLAIN}"
echo -e "${GREEN}2. hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_PIN_ENC}#Hy2-Pin${PLAIN}"
echo -e ""
echo -e "管理: /usr/local/bin/hy2-restart.sh | cat /etc/hysteria/config.yaml"
