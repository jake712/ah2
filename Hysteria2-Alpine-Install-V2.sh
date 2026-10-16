#!/bin/bash
# Hysteria2 V3.5 完整永活旗艦版 - 修復版 for curl | bash
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'

CUSTOM_PORT=""; CUSTOM_PASSWORD=""; CUSTOM_IP=""; CUSTOM_OS="auto"
while getopts "p:w:i:o:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    o) CUSTOM_OS=$OPTARG ;;
    h) echo "用法: $0 [-o debian|alpine|auto] [-p 端口] [-w 密码] [-i IP]"; exit 0 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}请用 root 运行${PLAIN}"
  exit 1
fi

detect_os(){
  local T="unknown"
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in alpine) T="alpine";; debian|ubuntu) T="debian";; esac
    case "$ID_LIKE" in *debian*|*ubuntu*) T="debian";; *alpine*) T="alpine";; esac
  fi
  if [ "$T" = "unknown" ]; then
    command -v apk >/dev/null 2>&1 && T="alpine"
    command -v apt-get >/dev/null 2>&1 && T="debian"
  fi
  echo "$T"
}

FINAL_OS=$(detect_os)
if [ "$CUSTOM_OS" != "auto" ]; then
  FINAL_OS=$CUSTOM_OS
fi
if [ "$FINAL_OS" = "unknown" ]; then
  FINAL_OS="debian"
fi

echo -e "${GREEN}=== Hysteria2 V3.5 完整永活版 [${FINAL_OS}] ===${PLAIN}"

if [ "$FINAL_OS" = "alpine" ]; then
  apk update
  apk add --no-cache curl wget openssl bind-tools iproute2 procps ca-certificates python3 iptables dcron
  rc-update add dcron default 2>/dev/null || true
  rc-service dcron start 2>/dev/null || true
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget openssl bind9-dnsutils iproute2 procps ca-certificates python3 cron iptables ufw 2>/dev/null || apt-get install -y curl wget openssl procps ca-certificates python3 cron
  systemctl enable cron 2>/dev/null || systemctl enable cronie 2>/dev/null || true
  systemctl start cron 2>/dev/null || systemctl start cronie 2>/dev/null || true
fi

HY_PORT=${CUSTOM_PORT:-33950}
HY_PASS=${CUSTOM_PASSWORD:-$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)}
if [ -z "$HY_PASS" ]; then
  HY_PASS="Hy2$(date +%s | tail -c 6)"
fi
OBFS_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  *) HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log
chmod 700 /etc/hysteria

cat > /etc/sysctl.d/99-hysteria.conf <<SYSCTL
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_mem = 102400 873800 16777216
SYSCTL
sysctl -p /etc/sysctl.d/99-hysteria.conf >/dev/null 2>&1 || true

HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" || wget -q -O /tmp/hysteria "$HY_URL" || true
if [ ! -s /tmp/hysteria ]; then
  echo -e "${RED}下载失败${PLAIN}"
  exit 1
fi
mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  chmod 600 /etc/hysteria/key.key
fi

cat > /etc/hysteria/config.yaml <<EOF
listen: 0.0.0.0:${HY_PORT}
auth:
  type: password
  password: ${HY_PASS}
obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASS}
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
fastOpen: true
bandwidth:
  up: 0
  down: 0
EOF

cat > /usr/local/bin/hy2-keepalive.sh <<KEEP
#!/bin/sh
BIN="/usr/local/bin/hysteria"
CONF="/etc/hysteria/config.yaml"
LOG="/var/log/hysteria.log"
PORT="${HY_PORT}"
if [ -f "\$LOG" ]; then
  SIZE=\$(wc -c < "\$LOG" 2>/dev/null || echo 0)
  if [ "\$SIZE" -gt 52428800 ]; then
    : > "\$LOG"
  fi
fi
if ! pgrep -f "hysteria.*config.yaml" >/dev/null 2>&1; then
  echo "\$(date) [keepalive] restart" >> "\$LOG"
  nohup setsid \$BIN server -c \$CONF >> "\$LOG" 2>&1 &
  exit 0
fi
if command -v ss >/dev/null 2>&1; then
  ss -uln | grep -q ":\$PORT" || { pkill -f "hysteria.*config.yaml"; sleep 1; nohup setsid \$BIN server -c \$CONF >> "\$LOG" 2>&1 & }
fi
KEEP
chmod +x /usr/local/bin/hy2-keepalive.sh

cat > /usr/local/bin/hy2 <<'MGR'
#!/bin/bash
CONF="/etc/hysteria/config.yaml"
LOG="/var/log/hysteria.log"
case "$1" in
  status)
    if [ -d /run/systemd/system ]; then
      systemctl status hysteria --no-pager -l 2>/dev/null || systemctl status hysteria
    else
      pgrep -a hysteria; ss -ulnp 2>/dev/null | grep hysteria || netstat -ulnp 2>/dev/null | grep hysteria
    fi
    crontab -l 2>/dev/null | grep hy2 || echo "无 cron"
    ;;
  log) tail -n 100 -f "$LOG" ;;
  restart) pkill -f "hysteria.*config.yaml"; sleep 1; /usr/local/bin/hy2-keepalive.sh; [ -d /run/systemd/system ] && systemctl restart hysteria 2>/dev/null || true; echo "已重启" ;;
  start) /usr/local/bin/hy2-keepalive.sh; [ -d /run/systemd/system ] && systemctl start hysteria 2>/dev/null || true ;;
  stop) pkill -f "hysteria.*config.yaml"; [ -d /run/systemd/system ] && systemctl stop hysteria 2>/dev/null || true; echo "已停止" ;;
  info) cat /root/hy2-info.txt 2>/dev/null || echo "未找到信息文件" ;;
  url) cat /root/hy2-info.txt 2>/dev/null | grep hysteria2 ;;
  uninstall)
    read -p "确定要卸载? y/n: " c
    if [ "$c" != "y" ]; then exit 0; fi
    systemctl stop hysteria 2>/dev/null; systemctl disable hysteria 2>/dev/null; rm -f /etc/systemd/system/hysteria.service; systemctl daemon-reload 2>/dev/null || true
    rc-update del hysteria default 2>/dev/null; rm -f /etc/init.d/hysteria
    pkill -f "hysteria.*config.yaml" 2>/dev/null || true
    crontab -l 2>/dev/null | grep -v hy2-keepalive | crontab - 2>/dev/null || true
    rm -rf /etc/hysteria /usr/local/bin/hysteria /usr/local/bin/hy2-keepalive.sh /var/log/hysteria.log /root/hy2-*.yaml /root/hy2-*.json /root/hy2-info.txt /root/hy2-cert.crt
    rm -f /usr/local/bin/hy2; echo "已卸载完成"
    ;;
  *) echo "用法: hy2 {status|log|restart|start|stop|info|url|uninstall}" ;;
esac
MGR
chmod +x /usr/local/bin/hy2

if [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/hysteria.service <<SERVICE
[Unit]
Description=Hysteria2 V3.5 永活版
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
SERVICE
  systemctl daemon-reload
  systemctl enable hysteria 2>/dev/null || true
  systemctl restart hysteria || true
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
  chmod +x /etc/init.d/hysteria
  rc-update add hysteria default 2>/dev/null || true
  rc-service hysteria restart 2>/dev/null || rc-service hysteria start 2>/dev/null || /usr/local/bin/hy2-keepalive.sh
fi

(crontab -l 2>/dev/null | grep -v "hy2-keepalive" || true; echo "*/1 * * * * /usr/local/bin/hy2-keepalive.sh >/dev/null 2>&1"; echo "@reboot sleep 15 && /usr/local/bin/hy2-keepalive.sh >/dev/null 2>&1") | crontab - 2>/dev/null || true

if command -v ufw >/dev/null 2>&1; then ufw allow ${HY_PORT}/udp 2>/dev/null || true; fi
if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --permanent --add-port=${HY_PORT}/udp 2>/dev/null; firewall-cmd --reload 2>/dev/null || true; fi
iptables -C INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || true

if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP; else SERVER_IP=$(curl -4fsSL --max-time 4 https://api4.ipify.org 2>/dev/null || curl -4fsSL https://ifconfig.me 2>/dev/null || echo "YOUR_PUBLIC_IP"); fi

urlencode(){
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null || echo "$1"
}

CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary 2>/dev/null | openssl enc -base64 2>/dev/null | tr -d '\n')
if [ -z "$CERT_PIN" ]; then
  CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout | openssl rsa -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')
fi
CERT_PIN_ENC=$(urlencode "$CERT_PIN")
OBFS_ENC=$(urlencode "$OBFS_PASS")
cp /etc/hysteria/cert.crt /root/hy2-cert.crt 2>/dev/null || true

cat > /root/hy2-client.yaml <<EOF
server: ${SERVER_IP}:${HY_PORT}
auth: ${HY_PASS}
obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASS}
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
    obfs: salamander
    obfs-password: ${OBFS_PASS}
    sni: bing.com
    skip-cert-verify: false
    pinSHA256: ${CERT_PIN}
EOF

cat > /root/hy2-singbox.json <<EOF
{
  "type": "hysteria2",
  "tag": "Hy2-${SERVER_IP}",
  "server": "${SERVER_IP}",
  "server_port": ${HY_PORT},
  "password": "${HY_PASS}",
  "obfs": { "type": "salamander", "password": "${OBFS_PASS}" },
  "tls": { "enabled": true, "server_name": "bing.com", "pinSHA256": "${CERT_PIN}" }
}
EOF

SHARE1="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&obfs=salamander&obfs-password=${OBFS_ENC}&pinSHA256=${CERT_PIN_ENC}#Hy2-Pin-Obfs"
SHARE2="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&obfs=salamander&obfs-password=${OBFS_ENC}&insecure=1#Hy2-Obfs-Insecure"
SHARE3="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2-Insecure"

cat > /root/hy2-info.txt <<EOF
========== Hysteria2 V3.5 完整版 ==========
IP: ${SERVER_IP}
端口: ${HY_PORT}
密码: ${HY_PASS}
Obfs密码: ${OBFS_PASS}
pinSHA256: ${CERT_PIN}

--- Karing / Clash 推荐 ---
${SHARE1}

--- 兼容 ---
${SHARE2}

--- 通用 ---
${SHARE3}

文件: /root/hy2-clash.yaml /root/hy2-client.yaml /root/hy2-singbox.json
管理: hy2 status / hy2 log / hy2 restart
EOF

echo ""
echo -e "${GREEN}========== V3.5 安装完成 ==========${PLAIN}"
cat /root/hy2-info.txt
