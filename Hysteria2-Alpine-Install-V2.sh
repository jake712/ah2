#!/bin/bash
# Hysteria 2 一键安装脚本 for Alpine Linux (OpenRC) - 无默认端口版
# 用法: ./hysteria2-alpine-install.sh -p 443 -w "你的密码"
#      PORT=443 PASSWORD=xxx ./hysteria2-alpine-install.sh
# 必须指定 -p，否则会强制交互输入

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CUSTOM_PORT=""
CUSTOM_PASSWORD=""

while getopts "p:w:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    h)
      echo "用法: $0 -p 端口 -w 密码"
      echo "  -p  自定义端口 (1-65535) 必填"
      echo "  -w  自定义密码, 默认随机生成"
      echo "  环境变量: PORT=xxx PASSWORD=xxx $0"
      exit 0
      ;;
  esac
done

CUSTOM_PORT=${CUSTOM_PORT:-${PORT:-}}
CUSTOM_PASSWORD=${CUSTOM_PASSWORD:-${PASSWORD:-}}

if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}错误: 请使用 root 用户运行${PLAIN}"
  exit 1
fi

if [ ! -f /etc/alpine-release ]; then
  echo -e "${YELLOW}警告: 未检测到 Alpine 系统，但将继续尝试...${PLAIN}"
fi

get_arch() {
  ARCH=$(uname -m)
  case $ARCH in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *) echo "amd64" ;;
  esac
}

gen_password() {
  openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 16
  echo
}

validate_port() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
      ;;
  esac
}

if [ -z "$CUSTOM_PORT" ]; then
  while true; do
    read -p "请输入 Hysteria 2 端口 (1-65535 必填): " input_port
    if validate_port "$input_port"; then
      HY_PORT=$input_port
      break
    else
      echo -e "${RED}无效端口，请输入 1-65535${PLAIN}"
    fi
  done
else
  if ! validate_port "$CUSTOM_PORT"; then
    echo -e "${RED}错误: 端口 $CUSTOM_PORT 无效，必须是 1-65535${PLAIN}"
    exit 1
  fi
  HY_PORT=$CUSTOM_PORT
fi

if [ -z "$CUSTOM_PASSWORD" ]; then
  read -p "请输入 Hysteria 2 密码 [回车随机生成]: " input_pass
  if [ -z "$input_pass" ]; then
    HY_PASS=$(gen_password)
    echo -e "${YELLOW}已随机生成密码: $HY_PASS${PLAIN}"
  else
    HY_PASS=$input_pass
  fi
else
  HY_PASS=$CUSTOM_PASSWORD
fi

echo -e "${GREEN}=== 开始安装 Hysteria 2 ===${PLAIN}"
echo -e "端口: ${GREEN}$HY_PORT${PLAIN}"
echo -e "密码: ${GREEN}$HY_PASS${PLAIN}"

echo -e "${YELLOW}[1/6] 安装依赖...${PLAIN}"
apk update
apk add --no-cache bash curl wget openssl tar iproute2 jq

echo -e "${YELLOW}[2/6] 下载 Hysteria 2...${PLAIN}"
ARCH_TYPE=$(get_arch)
HY_BIN_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH_TYPE}"
mkdir -p /usr/local/bin /tmp
rm -f /usr/local/bin/hysteria /tmp/hysteria
echo "下载: $HY_BIN_URL"

# 先检查磁盘空间
echo "磁盘: $(df -h /usr/local/bin | tail -1)"

# 修复 curl 23 写入错误：先下载到 /tmp，再移动，带重试和备用工具
download_ok=0
if command -v curl >/dev/null 2>&1; then
  echo "尝试 curl 下载..."
  if curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o /tmp/hysteria "$HY_BIN_URL"; then
    download_ok=1
  else
    echo -e "${YELLOW}curl 失败，错误码 $?，尝试 wget...${PLAIN}"
  fi
fi

if [ $download_ok -eq 0 ] && command -v wget >/dev/null 2>&1; then
  if wget -O /tmp/hysteria "$HY_BIN_URL"; then
    download_ok=1
  fi
fi

if [ $download_ok -eq 0 ]; then
  echo -e "${RED}下载失败，可能原因：磁盘满、GitHub 被墙、内存不足${PLAIN}"
  echo "请手动执行："
  echo "  df -h"
  echo "  curl -v -L $HY_BIN_URL -o /tmp/hysteria"
  exit 1
fi

mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria
/usr/local/bin/hysteria version || { echo -e "${RED}Hysteria 二进制文件下载失败${PLAIN}"; exit 1; }

echo -e "${YELLOW}[3/6] 生成 TLS 证书 (CN=bing.com)...${PLAIN}"
mkdir -p /etc/ssl/private
openssl ecparam -genkey -name prime256v1 -noout -out /etc/ssl/private/bing.key
openssl req -new -x509 -nodes -key /etc/ssl/private/bing.key -out /etc/ssl/private/bing.crt -days 3650 -subj "/CN=bing.com"
chmod 600 /etc/ssl/private/bing.key
chmod 644 /etc/ssl/private/bing.crt

echo -e "${YELLOW}[4/6] 生成配置文件...${PLAIN}"
mkdir -p /etc/hysteria
cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}

tls:
  cert: /etc/ssl/private/bing.crt
  key: /etc/ssl/private/bing.key

auth:
  type: password
  password: "${HY_PASS}"

ignoreClientBandwidth: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
EOF

echo -e "${YELLOW}[5/6] 创建 OpenRC 服务...${PLAIN}"
cat > /etc/init.d/hysteria <<'SERVICE_EOF'
#!/sbin/openrc-run
name="Hysteria 2 Service"
description="Hysteria 2 Proxy Server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
depend() {
    need net
    after firewall
}
start_pre() {
    checkpath --directory --mode 0755 /run
    checkpath --file --mode 0644 /var/log/hysteria.log
}
SERVICE_EOF

chmod +x /etc/init.d/hysteria
rc-update add hysteria default

echo -e "${YELLOW}[6/6] 启动服务...${PLAIN}"
rc-service hysteria restart || rc-service hysteria start
sleep 2
rc-service hysteria status

get_ip() {
  _ip=$(curl -4 -s --max-time 3 https://ifconfig.me || curl -4 -s --max-time 3 https://ipinfo.io/ip || echo "YOUR_SERVER_IP")
  echo "$_ip"
}
SERVER_IP=$(get_ip)

echo ""
echo -e "${GREEN}========== 安装完成 ==========${PLAIN}"
echo -e "监听端口: ${GREEN}${HY_PORT} (UDP)${PLAIN}"
echo -e "认证密码: ${GREEN}${HY_PASS}${PLAIN}"
echo -e "配置文件: ${GREEN}/etc/hysteria/config.yaml${PLAIN}"
echo -e "证书: ${GREEN}/etc/ssl/private/bing.crt${PLAIN}"
echo -e "服务管理: ${GREEN}rc-service hysteria [start|stop|restart|status]${PLAIN}"
echo ""
echo -e "${YELLOW}客户端配置 (config.yaml 示例):${PLAIN}"
cat <<CLIENT_EOF

server: ${SERVER_IP}:${HY_PORT}
auth: ${HY_PASS}
tls:
  sni: bing.com
  insecure: true
bandwidth:
  up: 100 mbps
  down: 100 mbps
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080

CLIENT_EOF

echo -e "${YELLOW}Hysteria 2 分享链接 (URI):${PLAIN}"
ENCODED_PASS=$(echo -n "$HY_PASS" | jq -sRr @uri 2>/dev/null || echo "$HY_PASS")
echo -e "${GREEN}hysteria2://${ENCODED_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Alpine-Hy2${PLAIN}"
echo ""
echo -e "${YELLOW}注意: 请在防火墙/安全组放行 UDP ${HY_PORT} 端口${PLAIN}"
echo -e "查看日志: ${GREEN}cat /var/log/hysteria.log${PLAIN}"
echo ""
