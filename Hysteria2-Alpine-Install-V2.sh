#!/bin/bash
# Hysteria2 V3.0 永活版 - 基於你 V2.7 修改
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'
CUSTOM_PORT=""; CUSTOM_PASSWORD=""; CUSTOM_IP=""; CUSTOM_OS="auto"
while getopts "p:w:i:o:h" opt; do
  case $opt in p) CUSTOM_PORT=$OPTARG;; w) CUSTOM_PASSWORD=$OPTARG;; i) CUSTOM_IP=$OPTARG;; o) CUSTOM_OS=$OPTARG;; h) echo "用法: $0 [-o debian|alpine|auto] [-p 端口] [-w 密码] [-i IP]"; exit 0;; esac
done
if [ "$(id -u)"!= "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

detect_os(){ local T="unknown"; if [ -f /etc/os-release ]; then. /etc/os-release; case "$ID" in alpine) T="alpine";; debian|ubuntu) T="debian";; esac; case "$ID_LIKE" in *debian*|*ubuntu*) T="debian";; *alpine*) T="alpine";; esac; fi; if [ "$T" = "unknown" ]; then command -v apk >/dev/null 2>&1 && T="alpine"; command -v apt-get >/dev/null 2>&1 && T="debian"; fi; echo "$T"; }
if [ "$CUSTOM_OS" = "debian" ]; then FINAL_OS="debian"; elif [ "$CUSTOM_OS" = "alpine" ]; then FINAL_OS="alpine"; else D=$(detect_os); FINAL_OS=$D; [ "$FINAL_OS" = "unknown" ] && FINAL_OS="debian"; fi

echo -e "${GREEN}=== Hysteria2 V3.0 永活版 [${FINAL_OS}] ===${PLAIN}"

if [ "$FINAL_OS" = "alpine" ]; then
  apk update; apk add --no-cache curl wget openssl bind-tools iproute2 procps ca-certificates python3 iptables dcron
  rc-update add dcron default 2>/dev/null || true; rc-service dcron start 2>/dev/null || true
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y; apt-get install -y curl wget openssl bind9-dnsutils iproute2 procps ca-certificates python3 cron iptables-persistent || apt-get install -y cron
  systemctl enable cron 2>/dev/null || true; systemctl start cron 2>/dev/null || true
fi

HY_PORT=${CUSTOM_PORT:-33950}
if [ -n "$CUSTOM_PASSWORD" ]; then HY_PASS=$CUSTOM_PASSWORD; else HY_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16); fi
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac

mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log; chmod 700 /etc/hysteria || true

# sysctl 優化 - QUIC 永活關鍵
cat > /etc/sysctl.d/99-hysteria.conf <<SYSCTL
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_mem = 102400 873800 16777216
SYSCTL
sysctl -p /etc/sysctl.d/99-hysteria.conf >/dev/null 2>&1 || true

HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria; curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" || wget -q -O /tmp/hysteria "$HY_URL" || true
[! -s /tmp/hysteria ] && { echo "下载失败"; exit 1; }
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria

if [! -f /etc/hysteria/cert.crt ] || [! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  chmod 600 /etc/hysteria/key.key
fi

# 修復點1: listen 改成 0.0.0.0 避免 IPv6 綁定失敗
cat > /etc/hysteria/config.yaml <<EOF
listen: 0.0.0.0:${HY_PORT}
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
quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
EOF

# 修復點2: 永活守護腳本
cat > /usr/local/bin/hy2-keepalive.sh <<KEEP
#!/bin/sh
BIN="/usr/local/bin/hysteria"
CONF="/etc/hysteria/config.yaml"
LOG="/var/log/hysteria.log"
PORT="${HY_PORT}"
# 日誌超過50M自動清空
if [ -f "\$LOG" ]; then
  SIZE=\$(wc -c < "\$LOG" 2>/dev/null || echo 0)
  [ "\$SIZE" -gt 52428800 ] && : > "\$LOG" && echo "\$(date) log truncated" >> "\$LOG"
fi
# 檢查進程
if! pgrep -f "hysteria.*config.yaml" >/dev/null 2>&1; then
  echo "\$(date) [keepalive] hysteria not running, restarting..." >> "\$LOG"
  nohup setsid \$BIN server -c \$CONF >> \$LOG 2>&1 &
  exit 0
fi
# 檢查端口是否真的在監聽 (防止假死)
if command -v ss >/dev/null 2>&1; then
  ss -uln 2>/dev/null | grep -q ":\$PORT" || { pkill -f "hysteria.*config.yaml"; sleep 1; nohup setsid \$BIN server -c \$CONF >> \$LOG 2>&1 & }
else
  netstat -uln 2>/dev/null | grep -q ":\$PORT" || { pkill -f "hysteria.*config.yaml"; sleep 1; nohup setsid \$BIN server -c \$CONF >> \$LOG 2>&1 & }
fi
KEEP
chmod +x /usr/local/bin/hy2-keepalive.sh

cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
/usr/local/bin/hy2-keepalive.sh
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl restart hysteria 2>/dev/null || true
fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh

# 修復點3: systemd 無限重啟
if [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 V3.0 永活版
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /run/hysteria
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
StartLimitInterval=0
StartLimitBurst=0
LimitNOFILE=1048576
KillMode=process
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable hysteria 2>/dev/null || true; systemctl restart hysteria || true
else
  cat > /etc/init.d/hysteria <<'INIT'
#!/sbin/openrc-run
name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria/hysteria.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
supervisor=supervise-daemon
depend() { need net; }
start_pre() { checkpath --directory --mode 0755 /run/hysteria; }
INIT
  chmod +x /etc/init.d/hysteria; rc-update add hysteria default 2>/dev/null || true; rc-service hysteria restart || rc-service hysteria start || /usr/local/bin/hy2-keepalive.sh
fi

# 修復點4: cron 保活 (對非systemd至關重要)
# 刪除舊的，寫入新的
(crontab -l 2>/dev/null | grep -v "hy2-keepalive" || true; echo "*/2 * * * * /usr/local/bin/hy2-keepalive.sh >/dev/null 2>&1"; echo "@reboot sleep 10 && /usr/local/bin/hy2-keepalive.sh >/dev/null 2>&1") | crontab - 2>/dev/null || true

iptables -C INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || true
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP; else SERVER_IP=$(curl -4fsSL --max-time 4 https://api4.ipify.org 2>/dev/null || echo "YOUR_PUBLIC_IP"); fi
urlencode(){ python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null || echo "$1" | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g'; }
CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary 2>/dev/null | openssl enc -base64 2>/dev/null | tr -d '\n')
[ -z "$CERT_PIN" ] && CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout | openssl rsa -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')
CERT_PIN_ENC=$(urlencode "$CERT_PIN")
CERT_FPR=$(openssl x509 -in /etc/hysteria/cert.crt -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
cp /etc/hysteria/cert.crt /root/hy2-cert.crt 2>/dev/null || true

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
proxies:
    - name: Hy2-${SERVER_IP}
    type: hysteria2
    server: ${SERVER_IP}
    port: ${HY_PORT}
    password: ${HY_PASS}
    sni: bing.com
    skip-cert-verify: false
    pinSHA256: ${CERT_PIN}
EOF

echo ""
echo -e "${GREEN}========== V3.0 永活版完成 [${FINAL_OS}] ==========${PLAIN}"
echo -e "端口: ${HY_PORT} | 密码: ${HY_PASS} | IP: ${SERVER_IP}"
echo -e "保活: 已啟用 (systemd無限重啟 + cron每2分鐘檢查)"
echo -e "守護腳本: /usr/local/bin/hy2-keepalive.sh"
echo -e "指纹: ${CERT_FPR}"
echo ""
echo -e "${GREEN}--- [Karing/Clash专用-推荐] ---${PLAIN}"
echo -e "hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_PIN_ENC}#Hy2-Karing-Pin"
echo ""
echo -e "${YELLOW}--- [兼容] ---${PLAIN}"
echo -e "hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2-Insecure"
echo ""
echo -e "檢查: ps aux | grep hysteria ; ss -ulnp | grep ${HY_PORT}"
echo -e "日誌: tail -f /var/log/hysteria.log"
echo -e "重啟: /usr/local/bin/hy2-restart.sh"
