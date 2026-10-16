#!/bin/bash
# Hysteria2 Universal V2.7 Final - Debian/Alpine + Karing修复完整版
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'
CUSTOM_PORT=""; CUSTOM_PASSWORD=""; CUSTOM_IP=""; CUSTOM_OS="auto"
while getopts "p:w:i:o:h" opt; do
  case $opt in p) CUSTOM_PORT=$OPTARG;; w) CUSTOM_PASSWORD=$OPTARG;; i) CUSTOM_IP=$OPTARG;; o) CUSTOM_OS=$OPTARG;; h) echo "用法: $0 [-o debian|alpine|auto] [-p 端口] [-w 密码] [-i IP]"; exit 0;; esac
done
if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi
detect_os(){ local T="unknown"; if [ -f /etc/os-release ]; then . /etc/os-release; case "$ID" in alpine) T="alpine";; debian|ubuntu) T="debian";; esac; case "$ID_LIKE" in *debian*|*ubuntu*) T="debian";; *alpine*) T="alpine";; esac; fi; if [ "$T" = "unknown" ]; then command -v apk >/dev/null 2>&1 && T="alpine"; command -v apt-get >/dev/null 2>&1 && T="debian"; fi; echo "$T"; }
if [ "$CUSTOM_OS" = "debian" ]; then FINAL_OS="debian"; elif [ "$CUSTOM_OS" = "alpine" ]; then FINAL_OS="alpine"; else D=$(detect_os); FINAL_OS=$D; [ "$FINAL_OS" = "unknown" ] && FINAL_OS="debian"; fi
echo -e "${GREEN}=== Hysteria2 V2.7 Karing修复完整版 [${FINAL_OS}] ===${PLAIN}"
if [ "$FINAL_OS" = "alpine" ]; then apk update; apk add --no-cache curl wget openssl bind-tools iproute2 procps ca-certificates python3; else export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y curl wget openssl bind9-dnsutils iproute2 procps ca-certificates python3 cron || true; fi
HY_PORT=${CUSTOM_PORT:-33950}
if [ -n "$CUSTOM_PASSWORD" ]; then HY_PASS=$CUSTOM_PASSWORD; else HY_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16); fi
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log; chmod 700 /etc/hysteria || true
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria; curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" || wget -q -O /tmp/hysteria "$HY_URL" || true
[ ! -s /tmp/hysteria ] && { echo "下载失败"; exit 1; }
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
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
cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q hysteria; then systemctl restart hysteria
else pkill -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1; nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh
if [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 V2.7
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
depend() { need net; }
start_pre() { checkpath --directory --mode 0755 /run/hysteria; }
INIT
  chmod +x /etc/init.d/hysteria; rc-update add hysteria default 2>/dev/null || true; rc-service hysteria restart || rc-service hysteria start || true
fi
iptables -C INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || true
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
# Karing / Clash.Meta 专用 - 最稳
proxies:
  - name: Hy2-${SERVER_IP}
    type: hysteria2
    server: ${SERVER_IP}
    port: ${HY_PORT}
    password: ${HY_PASS}
    sni: bing.com
    skip-cert-verify: false
    pinSHA256: ${CERT_PIN}
    # 如果Karing报错，把上面2行注释掉，打开下面2行
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
  "tls": { "enabled": true, "server_name": "bing.com", "pinSHA256": "${CERT_PIN}", "insecure": false, "alpn": "h3" }
}
EOF

echo ""
echo -e "${GREEN}========== V2.7 完成 [${FINAL_OS}] ==========${PLAIN}"
echo -e "端口: ${HY_PORT} | 密码: ${HY_PASS} | IP: ${SERVER_IP}"
echo -e "指纹: ${CERT_FPR}"
echo -e "pin原始: ${CERT_PIN}"
echo -e "pin编码: ${CERT_PIN_ENC}"
echo ""
echo -e "${GREEN}--- [Karing/Clash专用-推荐] 分享链接 (URL编码后) ---${PLAIN}"
echo -e "hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_PIN_ENC}#Hy2-Karing-Pin"
echo ""
echo -e "${YELLOW}--- [Karing兼容-带insecure] 如果上面还不行用这个 ---${PLAIN}"
echo -e "hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1&pinSHA256=${CERT_PIN_ENC}#Hy2-Karing-InsecurePin"
echo ""
echo -e "${YELLOW}--- [通用兼容] ---${PLAIN}"
echo -e "hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2-Insecure"
echo ""
echo -e "Clash文件: cat /root/hy2-clash.yaml"
echo -e "日志: journalctl -u hysteria -f 或 tail -f /var/log/hysteria.log"
echo -e "放行: UDP ${HY_PORT} 记得云厂商安全组也要放行"
