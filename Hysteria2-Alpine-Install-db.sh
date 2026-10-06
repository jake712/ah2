#!/bin/bash
# Hysteria2 Podman专用版 - 保证输出分享链接
set -e
YELLOW='\033[0;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

# 取消默认26169，随机端口
if [ -z "$1" ]; then
  if command -v shuf >/dev/null 2>&1; then
    HY_PORT=$(shuf -i 20000-60000 -n 1)
  else
    HY_PORT=$((RANDOM % 40000 + 20000))
  fi
else
  HY_PORT=$1
fi

# 第二个参数是密码
if [ -n "$2" ]; then
  HY_PASS=$2
else
  HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  [ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 6)"
fi

# 第三个参数是IP
if [ -n "$3" ]; then
  SERVER_IP=$3
else
  SERVER_IP=$(curl -4fsSL --max-time 4 https://api4.ipify.org 2>/dev/null || curl -4fsSL --max-time 4 https://ifconfig.me/ip 2>/dev/null || echo "YOUR_IP")
fi

echo -e "${YELLOW}[1/3] 下载...${PLAIN}"
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HA="amd64";; aarch64|arm64) HA="arm64";; *) HA="amd64";; esac
URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HA}"
curl -4fsSL --max-time 30 -o /tmp/hysteria "$URL" 2>/dev/null || wget -q -O /tmp/hysteria "$URL" 2>/dev/null || true
if [ ! -s /tmp/hysteria ]; then curl -4fsSL -o /tmp/hysteria "https://ghfast.top/$URL" 2>/dev/null || true; fi
mkdir -p /etc/hysteria /usr/local/bin
mv /tmp/hysteria /usr/local/bin/hysteria 2>/dev/null || true
chmod +x /usr/local/bin/hysteria

echo -e "${YELLOW}[2/3] 生成配置...${PLAIN}"
mkdir -p /etc/hysteria
if [ ! -f /etc/hysteria/cert.crt ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650 2>/dev/null
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

echo -e "${YELLOW}[3/3] 启动 (nohup, 不碰systemd)...${PLAIN}"
pkill -9 hysteria 2>/dev/null || true
sleep 1
nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
sleep 2
ps aux | grep hysteria | grep -v grep || true
ss -unlp 2>/dev/null | grep -E "$HY_PORT|hysteria" || netstat -unlp 2>/dev/null | grep "$HY_PORT" || cat /var/log/hysteria.log | tail -n 20

echo ""
echo -e "${GREEN}========== 完成 ==========${PLAIN}"
echo -e "端口: ${CYAN}${HY_PORT}${PLAIN}"
echo -e "密码: ${CYAN}${HY_PASS}${PLAIN}"
echo -e "IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo ""
echo -e "${GREEN}分享链接:${PLAIN}"
echo -e "hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Podman-${HY_PORT}"
echo ""
echo "重启: pkill hysteria; nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &"
