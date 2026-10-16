#!/bin/bash
# Hysteria2 V3.5 完整永活旗艦版 - Debian/Ubuntu/Alpine 通用
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'
CUSTOM_PORT=""; CUSTOM_PASSWORD=""; CUSTOM_IP=""; CUSTOM_OS="auto"
while getopts "p:w:i:o:h" opt; do
  case $opt in p) CUSTOM_PORT=$OPTARG;; w) CUSTOM_PASSWORD=$OPTARG;; i) CUSTOM_IP=$OPTARG;; o) CUSTOM_OS=$OPTARG;; h) echo "用法: $0 [-o debian|alpine|auto] [-p 端口] [-w 密码] [-i IP]"; exit 0;; esac
done
[ "$(id -u)"!= "0" ] && echo -e "${RED}请用 root 运行${PLAIN}" && exit 1

detect_os(){ local T="unknown"; [ -f /etc/os-release ] &&. /etc/os-release; case "$ID" in alpine) T="alpine";; debian|ubuntu) T="debian";; esac; case "$ID_LIKE" in *debian*|*ubuntu*) T="debian";; *alpine*) T="alpine";; esac; if [ "$T" = "unknown" ]; then command -v apk >/dev/null 2>&1 && T="alpine"; command -v apt-get >/dev/null 2>&1 && T="debian"; fi; echo "$T"; }
FINAL_OS=$(detect_os); [ "$CUSTOM_OS"!= "auto" ] && FINAL_OS=$CUSTOM_OS; [ "$FINAL_OS" = "unknown" ] && FINAL_OS="debian"
echo -e "${GREEN}=== Hysteria2 V3.5 完整永活版 [${FINAL_OS}] ===${PLAIN}"

# 依賴 + cron
if [ "$FINAL_OS" = "alpine" ]; then
  apk update; apk add --no-cache curl wget openssl bind-tools iproute2 procps ca-certificates python3 iptables dcron
  rc-update add dcron default 2>/dev/null || true; rc-service dcron start 2>/dev/null || true
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y; apt-get install -y curl wget openssl bind9-dnsutils iproute2 procps ca-certificates python3 cron iptables ufw 2>/dev/null || apt-get install -y curl wget openssl procps ca-certificates python3 cron
  systemctl enable cron 2>/dev/null || systemctl enable cronie 2>/dev/null || true; systemctl start cron 2>/dev/null || systemctl start cronie 2>/dev/null || true
fi

HY_PORT=${CUSTOM_PORT:-33950}
HY_PASS=${CUSTOM_PASSWORD:-$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)}
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 6)"
OBFS_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log; chmod 700 /etc/hysteria

# QUIC 優化
cat > /etc/sysctl.d/99-hysteria.conf <<SYS
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_mem = 102400 873800 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
SYS
sysctl -p /etc/sysctl.d/99-hysteria.conf >/dev/null 2>&1 || true

# 下載二進制
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria; curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" || wget -q -O /tmp/hysteria "$HY_URL" || true
[! -s /tmp/hysteria ] && echo -e "${RED}下載失敗，請手動檢查網絡${PLAIN}" && exit 1
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria

# 證書
if [! -f /etc/hysteria/cert.crt ] || [! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  chmod 600 /etc/hysteria/key.key
fi

# 核心修復: 0.0.0.0 監聽 + obfs + quic 調優
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
ignoreClientBandwidth: false
disableUDP: false
EOF

# 永活守護
cat > /usr/local/bin/hy2-keepalive.sh <<KEEP
#!/bin/sh
BIN="/usr/local/bin/hysteria"
CONF="/etc/hysteria/config.yaml"
LOG="/var/log/hysteria.log"
PORT="${HY_PORT}"
[ -f "\$LOG" ] && [ \$(wc -c < "\$LOG" 2>/dev/null || echo 0) -gt 52428800 ] && : > "\$LOG"
if! pgrep -f "hysteria.*config.yaml" >/dev/null 2>&1; then
  echo "\$(date) [keepalive] restart" >> "\$LOG"
  nohup setsid \$BIN server -c \$CONF >> "\$LOG" 2>&1 &
  exit 0
fi
if command -v ss >/dev/null 2>&1; then
  ss -uln | grep -q ":\$PORT" || { pkill -f "hysteria.*config.yaml"; sleep 1; nohup setsid \$BIN server -c \$CONF >> "\$LOG" 2>&1 & }
fi
KEEP
chmod +x /usr/local/bin/hy2-keepalive.sh

# 管理命令 hy2
cat > /usr/local/bin/hy2 <<'MGR'
#!/bin/bash
CONF="/etc/hysteria/config.yaml"; LOG="/var/log/hysteria.log"
case "$1" in
  status)
    if [ -d /run/systemd/system ]; then systemctl status hysteria --no-pager -l 2>/dev/null || systemctl status hysteria;
    else pgrep -a hysteria; ss -ulnp 2>/dev/null | grep -E "$HY_PORT|hysteria" || netstat -ulnp 2>/dev/null | grep hysteria; fi
    echo "--- cron ---"; crontab -l 2>/dev/null | grep hy2 || echo "無 cron"
    ;;
  log) tail -n 100 -f "$LOG" ;;
  restart) pkill -f "hysteria.*config.yaml"; sleep 1; /usr/local/bin/hy2-keepalive.sh; [ -d /run/systemd/system ] && systemctl restart hysteria 2>/dev/null || true; echo "已重啟" ;;
  start) /usr/local/bin/hy2-keepalive.sh; [ -d /run/systemd/system ] && systemctl start hysteria 2>/dev/null || true ;;
  stop) pkill -f "hysteria.*config.yaml"; [ -d /run/systemd/system ] && systemctl stop hysteria 2>/dev/null || true; echo "已停止" ;;
  info) cat /root/hy2-info.txt 2>/dev/null || echo "未找到信息文件" ;;
  url) cat /root/hy2-info.txt 2>/dev/null | grep hysteria2 ;;
  uninstall)
    read -p "確定要卸載 Hysteria2 嗎? 輸入 y 確認: " c; [ "$c" = "y" ] || exit 0
    systemctl stop hysteria 2>/dev/null; systemctl disable hysteria 2>/dev/null; rm -f /etc/systemd/system/hysteria.service; systemctl daemon-reload
    rc-update del hysteria default 2>/dev/null; rm -f /etc/init.d/hysteria
    pkill -f "hysteria.*config.yaml"; crontab -l 2>/dev/null | grep -v hy2-keepalive | crontab - 2>/dev/null || true
    rm -rf /etc/hysteria /usr/local/bin/hysteria /usr/local/bin/hy2-keepalive.sh /usr/local/bin/hy2-restart.sh /var/log/hysteria.log /root/hy2-*.yaml /root/hy2-*.json /root/hy2-info.txt /root/hy2-cert.crt
    rm -f /usr/local/bin/hy2; echo "已卸載完成"
    ;;
  *) echo "用法: hy2 {status|log|restart|start|stop|info|url|uninstall}" ;;
esac
MGR
chmod +x /usr/local/bin/hy2
ln -sf /usr/local/bin/hy2 /usr/local/bin/hy2-restart.sh 2>/dev/null || cat > /usr/local/bin/hy2-restart.sh <<'R'
#!/bin/sh
/usr/local/bin/hy2-keepalive.sh
R
chmod +x /usr/local/bin/hy2-restart.sh

# systemd 服務 - 無限重啟
if [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 V3.5 永活旗艦版
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
  systemctl daemon-reload; systemctl enable hysteria; systemctl restart hysteria || true
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

# cron 保活 - 最關鍵
(crontab -l 2>/dev/null | grep -v "hy2-keepalive" || true; echo "*/1 * * * * /usr/local/bin/hy2-keepalive.sh >/dev/null 2>&1"; echo "@reboot sleep 15 && /usr/local/bin/hy2-keepalive.sh >/dev/null 2>&1") | crontab - 2>/dev/null || true

# 防火牆
if command -v ufw >/dev/null 2>&1; then ufw allow ${HY_PORT}/udp 2>/dev/null || true; fi
if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --permanent --add-port=${HY_PORT}/udp 2>/dev/null; firewall-cmd --reload 2>/dev/null || true; fi
iptables -C INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || true

# IP和指紋
if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP; else SERVER_IP=$(curl -4fsSL --max-time 4 https://api4.ipify.org 2>/dev/null || curl -4fsSL https://ifconfig.me 2>/dev/null || echo "YOUR_PUBLIC_IP"); fi
urlencode(){ python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null || echo "$1"; }
CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')
[ -z "$CERT_PIN" ] && CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout | openssl rsa -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')
CERT_PIN_ENC=$(urlencode "$CERT_PIN")
OBFS_ENC=$(urlencode "$OBFS_PASS")
cp /etc/hysteria/cert.crt /root/hy2-cert.crt 2>/dev/null || true

# 客戶端配置
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
fastOpen: true
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
    fast-open: true
EOF

cat > /root/hy2-singbox.json <<EOF
{
  "type": "hysteria2",
  "tag": "Hy2-${SERVER_IP}",
  "server": "${SERVER_IP}",
  "server_port": ${HY_PORT},
  "password": "${HY_PASS}",
  "obfs": { "type": "salamander", "password": "${OBFS_PASS}" },
  "tls": { "enabled": true, "server_name": "bing.com", "pinSHA256": "${CERT_PIN}", "insecure": false, "alpn": "h3" }
}
EOF

SHARE1="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&obfs=salamander&obfs-password=${OBFS_ENC}&pinSHA256=${CERT_PIN_ENC}#Hy2-${SERVER_IP}-Pin-Obfs"
SHARE2="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&obfs=salamander&obfs-password=${OBFS_ENC}&insecure=1#Hy2-${SERVER_IP}-Obfs-Insecure"
SHARE3="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2-${SERVER_IP}-Insecure"

cat > /root/hy2-info.txt <<EOF
========== Hysteria2 V3.5 完整版 ==========
IP: ${SERVER_IP}
端口: ${HY_PORT}
密碼: ${HY_PASS}
Obfs密碼(salamander): ${OBFS_PASS}
pinSHA256: ${CERT_PIN}
指紋: $(openssl x509 -in /etc/hysteria/cert.crt -noout -fingerprint -sha256 | cut -d= -f2)

--- Karing / Clash.Meta 推薦 (最穩) ---
${SHARE1}

--- 兼容模式 ---
${SHARE2}

--- 通用不驗證 ---
${SHARE3}

文件:
  客戶端: /root/hy2-client.yaml
  Clash: /root/hy2-clash.yaml
  SingBox: /root/hy2-singbox.json
  證書: /root/hy2-cert.crt

命令:
  hy2 status 查看狀態
  hy2 log 看日誌
  hy2 restart 重啟
  hy2 url 只顯示鏈接
EOF

echo -e "${GREEN}========== V3.5 安裝完成 [${FINAL_OS}] ==========${PLAIN}"
cat /root/hy2-info.txt
echo -e "${YELLOW}提醒: 雲服務器安全組/防火牆請放行 UDP ${HY_PORT}${PLAIN}"
