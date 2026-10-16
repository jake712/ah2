#!/bin/bash
# Hysteria2 V3.7 保活加強版 - Debian/Ubuntu/Alpine 通用
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'

CUSTOM_PORT=""; CUSTOM_PASSWORD=""; CUSTOM_IP=""; CUSTOM_OS="auto"; NO_OBFS=""
while getopts "p:w:i:o:nh" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    o) CUSTOM_OS=$OPTARG ;;
    n) NO_OBFS="1" ;;
    h) echo "用法: $0 [-o debian|alpine|auto] [-p 端口] [-w 密码] [-i IP] [-n 不使用obfs]"; exit 0 ;;
  esac
done

[ "$(id -u)"!= "0" ] && echo -e "${RED}请用 root 运行${PLAIN}" && exit 1

detect_os(){
  local T="unknown"
  [ -f /etc/os-release ] &&. /etc/os-release
  case "$ID" in alpine) T="alpine";; debian|ubuntu) T="debian";; esac
  case "$ID_LIKE" in *debian*|*ubuntu*) T="debian";; *alpine*) T="alpine";; esac
  [ "$T" = "unknown" ] && command -v apk >/dev/null 2>&1 && T="alpine"
  [ "$T" = "unknown" ] && command -v apt-get >/dev/null 2>&1 && T="debian"
  echo "$T"
}
FINAL_OS=$(detect_os); [ "$CUSTOM_OS"!= "auto" ] && FINAL_OS=$CUSTOM_OS
[ "$FINAL_OS" = "unknown" ] && FINAL_OS="debian"
echo -e "${GREEN}=== Hysteria2 V3.7 保活加强版 [${FINAL_OS}] ===${PLAIN}"

if [ "$FINAL_OS" = "alpine" ]; then
  apk update
  apk add --no-cache curl wget openssl bind-tools iproute2 procps ca-certificates python3 iptables dcron util-linux
  rc-update add dcron default 2>/dev/null || true; rc-service dcron start 2>/dev/null || true
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget openssl bind9-dnsutils iproute2 procps ca-certificates python3 cron iptables util-linux 2>/dev/null || apt-get install -y curl wget openssl procps ca-certificates python3 cron util-linux
  systemctl enable cron 2>/dev/null || true; systemctl start cron 2>/dev/null || true
fi

HY_PORT=${CUSTOM_PORT:-443}
HY_PASS=${CUSTOM_PASSWORD:-$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)}
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 6)"
OBFS_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log; chmod 700 /etc/hysteria

HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" || wget -q -O /tmp/hysteria "$HY_URL" || true
[! -s /tmp/hysteria ] && echo -e "${RED}下载失败${PLAIN}" && exit 1
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria

if [! -f /etc/hysteria/cert.crt ] || [! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  chmod 600 /etc/hysteria/key.key
fi

# 配置
if [ "$NO_OBFS" = "1" ]; then
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
EOF
else
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
EOF
fi

# ================= 保活核心 1: 加强版 keepalive.sh =================
cat > /usr/local/bin/hy2-keepalive.sh <<KEEP
#!/bin/sh
BIN="/usr/local/bin/hysteria"
CONF="/etc/hysteria/config.yaml"
LOG="/var/log/hysteria.log"
PORT="${HY_PORT}"
LOCK="/run/hysteria/keepalive.lock"
mkdir -p /run/hysteria
# 防止并发重启
exec 200>\$LOCK
flock -n 200 || exit 0

# 日志过大自动清
if [ -f "\$LOG" ]; then
  S=\$(wc -c < "\$LOG" 2>/dev/null || echo 0)
  [ "\$S" -gt 52428800 ] && : > "\$LOG"
fi

NEED_RESTART=0
REASON=""

# 1. 进程检测
if! pgrep -f "hysteria.*config.yaml" >/dev/null 2>&1; then
  NEED_RESTART=1
  REASON="process_not_found"
else
  # 2. 端口检测 - 进程在但端口没监听算假死
  if! ss -uln 2>/dev/null | grep -q ":${HY_PORT} "; then
    NEED_RESTART=1
    REASON="port_not_listening"
  fi
fi

# 3. 二进制和配置自愈
[! -x "\$BIN" ] && NEED_RESTART=1 && REASON="binary_missing"
[! -f "\$CONF" ] && NEED_RESTART=1 && REASON="conf_missing"

if [ "\$NEED_RESTART" = "1" ]; then
  echo "\$(date '+%F %T') [keepalive] restart reason=\$REASON" >> "\$LOG"
  # 强制清理
  pkill -9 -f "hysteria.*config.yaml" 2>/dev/null || true
  sleep 1
  # 补防火墙
  iptables -C INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || true
  if [ -d /run/systemd/system ]; then
    systemctl restart hysteria 2>/dev/null || nohup setsid \$BIN server -c \$CONF >> "\$LOG" 2>&1 &
  else
    nohup setsid \$BIN server -c \$CONF >> "\$LOG" 2>&1 &
  fi
fi
KEEP
chmod +x /usr/local/bin/hy2-keepalive.sh

# ================= 保活核心 2: 常驻死循环监控 =================
cat > /usr/local/bin/hy2-monitor.sh <<MON
#!/bin/sh
while true; do
  /usr/local/bin/hy2-keepalive.sh >/dev/null 2>&1
  sleep 15
done
MON
chmod +x /usr/local/bin/hy2-monitor.sh

# 管理命令
cat > /usr/local/bin/hy2 <<'MGR'
#!/bin/bash
LOG="/var/log/hysteria.log"
case "$1" in
  status) systemctl status hysteria hysteria-keepalive --no-pager -l 2>/dev/null || pgrep -a hysteria; echo "---PORT---"; ss -ulnp 2>/dev/null | grep hysteria; echo "---CRON---"; crontab -l 2>/dev/null | grep hy2 ;;
  log) tail -n 200 -f "$LOG" ;;
  restart) pkill -9 -f "hysteria.*config.yaml"; sleep 1; /usr/local/bin/hy2-keepalive.sh; systemctl restart hysteria hysteria-keepalive 2>/dev/null || true; echo "已重启"; sleep 1; ss -ulnp | grep hysteria ;;
  stop) systemctl stop hysteria hysteria-keepalive 2>/dev/null; pkill -9 -f "hysteria.*config.yaml"; echo "已停止(keepalive仍会在15秒内拉起,如需彻底停止执行 hy2 uninstall)" ;;
  info) cat /root/hy2-info.txt ;;
  url) grep hysteria2 /root/hy2-info.txt ;;
  uninstall) read -p "确定卸载 y/n: " c; [ "$c" = "y" ] || exit 0; systemctl stop hysteria hysteria-keepalive 2>/dev/null; systemctl disable hysteria hysteria-keepalive 2>/dev/null; rm -f /etc/systemd/system/hysteria.service /etc/systemd/system/hysteria-keepalive.service; systemctl daemon-reload 2>/dev/null; pkill -9 -f hysteria; crontab -l 2>/dev/null | grep -v hy2 | crontab -; rm -rf /etc/hysteria /usr/local/bin/hysteria /usr/local/bin/hy2-keepalive.sh /usr/local/bin/hy2-monitor.sh /var/log/hysteria.log /root/hy2-*; rm -f /usr/local/bin/hy2; echo "已卸载" ;;
  *) echo "hy2 {status|log|restart|stop|info|url|uninstall}" ;;
esac
MGR
chmod +x /usr/local/bin/hy2

# ================= 保活核心 3: systemd 双服务 =================
if [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/hysteria.service <<SERVICE
[Unit]
Description=Hysteria2 V3.7
After=network.target network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /run/hysteria
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=2
RestartSteps=10
RestartMaxDelaySec=60
StartLimitBurst=0
LimitNOFILE=1048576
OOMScoreAdjust=-999
KillMode=mixed
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
SERVICE

  cat > /etc/systemd/system/hysteria-keepalive.service <<SERVICE2
[Unit]
Description=Hysteria2 Keepalive Monitor
After=hysteria.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/hy2-monitor.sh
Restart=always
RestartSec=5
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
SERVICE2

  systemctl daemon-reload
  systemctl enable hysteria hysteria-keepalive
  systemctl restart hysteria hysteria-keepalive
else
  # Alpine OpenRC 双服务
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
supervise_daemon_args="--respawn-delay 2 --respawn-max 0"
depend() { need net; }
start_pre() { checkpath --directory --mode 0755 /run/hysteria; }
INIT
  cat > /etc/init.d/hysteria-keepalive <<'INIT2'
#!/sbin/openrc-run
name="hysteria-keepalive"
command="/usr/local/bin/hy2-monitor.sh"
command_background=true
pidfile="/run/hysteria/keepalive.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
supervisor=supervise-daemon
depend() { need net; after hysteria; }
start_pre() { checkpath --directory --mode 0755 /run/hysteria; }
INIT2
  chmod +x /etc/init.d/hysteria /etc/init.d/hysteria-keepalive
  rc-update add hysteria default 2>/dev/null; rc-update add hysteria-keepalive default 2>/dev/null
  rc-service hysteria restart || rc-service hysteria start
  rc-service hysteria-keepalive restart || rc-service hysteria-keepalive start || nohup /usr/local/bin/hy2-monitor.sh >/dev/null 2>&1 &
fi

# ================= 保活核心 4: cron 三重保险 =================
(crontab -l 2>/dev/null | grep -v hy2 | grep -v hysteria || true; echo "*/1 * * * * /usr/local/bin/hy2-keepalive.sh >/dev/null 2>&1"; echo "@reboot sleep 10 && /usr/local/bin/hy2-keepalive.sh >/dev/null 2>&1"; echo "@reboot sleep 15 && nohup /usr/local/bin/hy2-monitor.sh >/dev/null 2>&1 &") | crontab -

if command -v ufw >/dev/null 2>&1; then ufw allow ${HY_PORT}/udp 2>/dev/null || true; fi
if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --permanent --add-port=${HY_PORT}/udp 2>/dev/null; firewall-cmd --reload 2>/dev/null || true; fi
iptables -C INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || true

if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP; else SERVER_IP=$(curl -4fsSL --max-time 4 https://api4.ipify.org 2>/dev/null || curl -4fsSL https://ifconfig.me 2>/dev/null || echo "YOUR_IP"); fi
urlencode(){ python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null || echo "$1"; }
CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')
[ -z "$CERT_PIN" ] && CERT_PIN=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout | openssl rsa -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')
PIN_ENC=$(urlencode "$CERT_PIN"); OBFS_ENC=$(urlencode "$OBFS_PASS")
cp /etc/hysteria/cert.crt /root/hy2-cert.crt 2>/dev/null || true

cat > /root/hy2-client.yaml <<EOF
server: ${SERVER_IP}:${HY_PORT}
auth: ${HY_PASS}
$(if [ "$NO_OBFS"!= "1" ]; then echo "obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASS}"; fi)
tls:
  sni: bing.com
  pinSHA256: ${CERT_PIN}
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080
EOF

if [ "$NO_OBFS" = "1" ]; then
  SHARE1="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${PIN_ENC}#Hy2-Pin"
  SHARE2="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2-Insecure"
else
  SHARE1="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&obfs=salamander&obfs-password=${OBFS_ENC}&pinSHA256=${PIN_ENC}#Hy2-Pin-Obfs"
  SHARE2="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&obfs=salamander&obfs-password=${OBFS_ENC}&insecure=1#Hy2-Obfs"
fi

cat > /root/hy2-info.txt <<EOF
========== Hysteria2 V3.7 保活加强版 ==========
IP: ${SERVER_IP}
端口: ${HY_PORT} (UDP)
密码: ${HY_PASS}
Obfs: ${OBFS_PASS}
pinSHA256: ${CERT_PIN}

--- 推荐 Karing/Clash ---
${SHARE1}
--- 兼容 ---
${SHARE2}

保活: systemd双服务 + 15秒死循环监控 + 1分钟cron
管理: hy2 status | hy2 log | hy2 restart
EOF

sleep 2
echo -e "${GREEN}========== 安装完成 ==========${PLAIN}"
cat /root/hy2-info.txt
echo ""
echo "--- 保活自检 ---"
ss -ulnp | grep -E "${HY_PORT}|hysteria" || echo -e "${RED}端口未监听! 执行 hy2 log 看看${PLAIN}"
ps aux | grep -v grep | grep hysteria || echo -e "${RED}进程未运行!${PLAIN}"
[ -d /run/systemd/system ] && systemctl is-active hysteria hysteria-keepalive
