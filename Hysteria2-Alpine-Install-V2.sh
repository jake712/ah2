#!/bin/sh
# Hysteria 2 Alpine V3.8 - 修复v2rayN/Karing证书连接
# 基于 jake712 V3.7

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

echo -e "${GREEN}=== Hysteria2 Alpine V3.8 证书修复版 ===${PLAIN}"

# ===== [1/6] 基础依赖 =====
echo -e "${YELLOW}[1/6] 检查依赖...${PLAIN}"
if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "Podman DNS 保留"
else
  [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf && echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
fi

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || apk add --no-cache -q "$2" 2>&1 || apk add --no-cache "$2"
}
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || apk add --no-cache curl
ensure_cmd openssl openssl
ensure_cmd dig bind-tools
command -v ss >/dev/null 2>&1 || apk add --no-cache iproute2 2>/dev/null || true
[ ! -f /etc/ssl/certs/ca-certificates.crt ] && apk add --no-cache ca-certificates && update-ca-certificates 2>/dev/null || true

# ===== [2/6] 参数 =====
echo -e "${YELLOW}[2/6] 初始化...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-26169}
if [ -n "$CUSTOM_PASSWORD" ]; then HY_PASS=$CUSTOM_PASSWORD
else HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16); [ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"; fi

ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; arm*) HY_ARCH="arm";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log; chmod 700 /etc/hysteria 2>/dev/null || true

# ===== [3/6] 下载 =====
echo -e "${YELLOW}[3/6] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria; download_ok=0
for i in 1 2 3; do
  curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" 2>/dev/null && download_ok=1 && break
  wget -q --timeout=30 -O /tmp/hysteria "$HY_URL" 2>/dev/null && download_ok=1 && break
  sleep 1
done
if [ "$download_ok" != "1" ]; then
  for mirror in "https://ghfast.top/$HY_URL" "https://ghproxy.net/$HY_URL"; do
    curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
  done
fi
[ ! -s /tmp/hysteria ] && echo -e "${RED}下载失败${PLAIN}" && exit 1
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria

# ===== [4/6] 证书和配置 =====
echo -e "${YELLOW}[4/6] 生成证书和配置...${PLAIN}"
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  chmod 600 /etc/hysteria/key.key
fi

# ===== 关键修复: 计算证书 pinSHA256 =====
CERT_PIN_HEX=$(openssl x509 -noout -fingerprint -sha256 -in /etc/hysteria/cert.crt | cut -d'=' -f2 | tr -d ':' | tr 'A-Z' 'a-z')
CERT_PIN_B64=$(openssl x509 -in /etc/hysteria/cert.crt -pubkey -noout | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')
echo -e "证书 HEX pin: ${CYAN}${CERT_PIN_HEX}${PLAIN}"
echo -e "证书 B64 pin: ${CYAN}${CERT_PIN_B64}${PLAIN}"

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

# ===== [5/6] 服务 =====
echo -e "${YELLOW}[5/6] 启动服务...${PLAIN}"
if [ -f /sbin/openrc-run ] || command -v rc-update >/dev/null 2>&1; then
  cat > /etc/init.d/hysteria <<'EOS'
#!/sbin/openrc-run
name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
depend() { need net; after firewall; }
start_pre() { checkpath --directory --mode 0755 /run/hysteria; checkpath --directory --mode 0755 /etc/hysteria; }
EOS
  chmod +x /etc/init.d/hysteria; rc-update add hysteria default >/dev/null 2>&1 || true
  rc-service hysteria restart 2>&1 || rc-service hysteria start 2>&1 || true
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
  cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
pkill -f "hysteria.*config.yaml" || true; sleep 1
nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
echo "已重启"
RESTART
  chmod +x /usr/local/bin/hy2-restart.sh
fi
sleep 2; tail -n 20 /var/log/hysteria.log 2>/dev/null || true

# ===== [6/6] IP检测 =====
is_private_ip() { case "$1" in 0.0.0.0|10.*|192.168.*|127.*|169.254.*) return 0;; 172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0;; esac; echo "$1" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.' && return 0; return 1; }
get_ssh_ip() { [ -n "$SSH_CONNECTION" ] && echo "$SSH_CONNECTION" | awk '{print $3}' && return; ss -tn 2>/dev/null | grep ':22' | awk '{print $4}' | cut -d: -f1 | grep -E '^[0-9.]+$' | grep -v '^127\.' | head -n1; }
get_pub_ip() {
  local ip; if command -v dig >/dev/null 2>&1; then
    for ns in "208.67.222.222" "8.8.8.8" "1.1.1.1"; do
      ip=$(dig +short +time=2 +tries=1 @${ns} myip.opendns.com 2>/dev/null | grep -Eo '[0-9.]{7,15}' | head -n1)
      [ -n "$ip" ] && ! is_private_ip "$ip" && echo "$ip" && return
    done
  fi
  if command -v curl >/dev/null 2>&1; then
    for api in "https://api4.ipify.org" "https://ifconfig.me/ip" "https://ip.sb"; do
      ip=$(curl -4fsSL --max-time 4 "$api" 2>/dev/null | grep -Eo '[0-9.]{7,15}' | head -n1)
      [ -n "$ip" ] && ! is_private_ip "$ip" && echo "$ip" && return
    done
  fi
}
if [ -n "$CUSTOM_IP" ]; then SERVER_IP=$CUSTOM_IP
else SIP=$(get_ssh_ip); PIP=$(get_pub_ip); if is_private_ip "$SIP"; then [ -n "$PIP" ] && SERVER_IP=$PIP || SERVER_IP=$SIP; else [ -n "$SIP" ] && SERVER_IP=$SIP || SERVER_IP=$PIP; fi; fi
[ -z "$SERVER_IP" ] && SERVER_IP="YOUR_PUBLIC_IP"

# ===== [7/6] 关键新增: 生成 v2rayN/Karing 可用连接 =====
echo -e "${YELLOW}[7/6] 生成 v2rayN / Karing 客户端配置...${PLAIN}"

LINK_INSECURE="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Alpine-Hy2-V3.8-Insecure"
LINK_PIN_HEX="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_PIN_HEX}#Alpine-Hy2-V3.8-PIN"
LINK_PIN_B64="hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&pinSHA256=${CERT_PIN_B64}#Alpine-Hy2-V3.8-PIN-B64"

mkdir -p /root
cat > /etc/hysteria/client.yaml <<EOF
server: ${SERVER_IP}:${HY_PORT}
auth: ${HY_PASS}
tls:
  sni: bing.com
  insecure: true
  pinSHA256: ${CERT_PIN_HEX}
bandwidth:
  up: 20 mbps
  down: 100 mbps
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080
EOF

cat > /root/hy2-singbox.json <<EOF
{
  "outbounds": [{
    "type": "hysteria2",
    "tag": "hy2",
    "server": "${SERVER_IP}",
    "server_port": ${HY_PORT},
    "password": "${HY_PASS}",
    "tls": {
      "enabled": true,
      "server_name": "bing.com",
      "insecure": false,
      "certificate": ["${CERT_PIN_HEX}"]
    }
  }]
}
EOF

cat > /root/hy2-links.txt <<EOF
# Hysteria2 V3.8 客户端
端口: ${HY_PORT}
密码: ${HY_PASS}
IP: ${SERVER_IP}
SNI: bing.com
HEX PIN: ${CERT_PIN_HEX}
B64 PIN: ${CERT_PIN_B64}

1. v2rayN / v2rayNG 通用 (推荐先用这个):
${LINK_INSECURE}

2. Karing / Hiddify 安全版 (不跳过验证):
${LINK_PIN_HEX}

3. Karing B64版 (部分版本需要):
${LINK_PIN_B64}

客户端文件:
- /etc/hysteria/client.yaml (hysteria官方客户端直接用)
- /etc/hysteria/cert.crt (可手动导入)
- /root/hy2-singbox.json
EOF

chmod 600 /root/hy2-links.txt /etc/hysteria/client.yaml /root/hy2-singbox.json

echo ""
echo -e "${GREEN}========== V3.8 完成 ==========${PLAIN}"
echo -e "端口: ${CYAN}${HY_PORT}${PLAIN}  密码: ${CYAN}${HY_PASS}${PLAIN}  IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo -e ""
echo -e "${YELLOW}v2rayN / v2rayNG 直接导入 (insecure):${PLAIN}"
echo -e "${GREEN}${LINK_INSECURE}${PLAIN}"
echo -e ""
echo -e "${YELLOW}Karing / Hiddify 推荐 (pinSHA256 安全):${PLAIN}"
echo -e "${GREEN}${LINK_PIN_HEX}${PLAIN}"
echo -e ""
echo -e "配置文件已导出:"
echo -e "  cat /root/hy2-links.txt"
echo -e "  cat /etc/hysteria/client.yaml"
echo -e "  cat /etc/hysteria/cert.crt"
echo -e "  cat /root/hy2-singbox.json"
echo -e ""
echo -e "日志: tail -f /var/log/hysteria.log"
