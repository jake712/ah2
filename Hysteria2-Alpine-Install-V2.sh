#!/bin/bash
# Hysteria 2 一键安装脚本 for Alpine Linux V3 - 完全修复版
# 用法: ./hysteria2-alpine-install-v3.sh -p 56764 -w "你的密码" -i "你的入口IP"
# 或者: curl -fsSL https://raw.githubusercontent.com/jake712/ah2/main/Hysteria2-Alpine-Install-V3.sh | bash -s -- -p 56764 -w '你的密码' -i 52.196.190.145
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'
DEFAULT_PORT=56764

while getopts "p:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) 
      echo "用法: $0 [-p 端口] [-w 密码] [-i 入口IP]"
      echo "  -p 端口  默认 $DEFAULT_PORT"
      echo "  -w 密码  默认随机生成"
      echo "  -i IP    手动指定对外展示的服务器IP (入口IP)，解决WARP/多IP问题"
      exit 0 
      ;;
  esac
done

CUSTOM_PORT=${CUSTOM_PORT:-${PORT:-}}
CUSTOM_PASSWORD=${CUSTOM_PASSWORD:-${PASSWORD:-}}
CUSTOM_IP=${CUSTOM_IP:-${SERVER_IP:-}}

if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

get_arch() {
  ARCH=$(uname -m)
  case $ARCH in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *) echo "amd64" ;;
  esac
}
gen_password() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; echo; }

if [ -z "$CUSTOM_PORT" ]; then 
  read -p "请输入端口 [默认 $DEFAULT_PORT]: " input_port
  HY_PORT=${input_port:-$DEFAULT_PORT}
else 
  HY_PORT=$CUSTOM_PORT
fi

if [ -z "$CUSTOM_PASSWORD" ]; then 
  read -p "请输入密码 [回车随机生成]: " input_pass
  if [ -z "$input_pass" ]; then 
    HY_PASS=$(gen_password)
    echo -e "${YELLOW}随机密码: $HY_PASS${PLAIN}"
  else 
    HY_PASS=$input_pass
  fi
else 
  HY_PASS=$CUSTOM_PASSWORD
fi

echo -e "${GREEN}=== 开始安装 Hysteria 2 V3 ===${PLAIN}"
echo -e "端口: $HY_PORT 密码: $HY_PASS 入口IP参数: ${CUSTOM_IP:-自动检测}"

echo -e "${YELLOW}[1/6] 安装依赖...${PLAIN}"
apk update
apk add --no-cache bash curl wget openssl tar iproute2 file

mkdir -p /usr/local/bin /etc/ssl/private /etc/hysteria /var/log

echo -e "${YELLOW}[2/6] 下载 Hysteria 2 (自动重试多镜像)...${PLAIN}"
ARCH_TYPE=$(get_arch)
BIN_NAME="hysteria-linux-${ARCH_TYPE}"
DEST="/usr/local/bin/hysteria"
URLS=(
"https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
"https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
"https://ghproxy.com/https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
"https://mirror.ghproxy.com/https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
)
download_success=0
for URL in "${URLS[@]}"; do
  echo -e " 尝试: $URL"
  rm -f "$DEST" /tmp/hy.download
  if curl -fL --connect-timeout 10 --max-time 60 -o /tmp/hy.download "$URL" 2>&1; then
    if head -c 20 /tmp/hy.download | grep -qi "<html"; then echo " -> 是HTML，跳过"; continue; fi
    if ! head -c 4 /tmp/hy.download | grep -q $'\x7fELF'; then echo " -> 不是ELF"; continue; fi
    SIZE=$(wc -c < /tmp/hy.download)
    if [ "$SIZE" -lt 2000000 ]; then echo " -> 太小 $SIZE"; continue; fi
    mv /tmp/hy.download "$DEST"
    chmod +x "$DEST"
    download_success=1
    echo -e "${GREEN} -> 成功 ($SIZE bytes)${PLAIN}"
    break
  else
    echo -e "${RED} -> 失败，试下一个${PLAIN}"
  fi
done
if [ "$download_success" -ne 1 ]; then echo -e "${RED}所有镜像失败${PLAIN}"; exit 1; fi
"$DEST" version

echo -e "${YELLOW}[3/6] 生成 TLS 证书...${PLAIN}"
openssl ecparam -genkey -name prime256v1 -noout -out /etc/ssl/private/bing.key
openssl req -new -x509 -nodes -key /etc/ssl/private/bing.key -out /etc/ssl/private/bing.crt -days 3650 -subj "/CN=bing.com"
chmod 600 /etc/ssl/private/bing.key
chmod 644 /etc/ssl/private/bing.crt

echo -e "${YELLOW}[4/6] 生成配置文件...${PLAIN}"
cat > /etc/hysteria/config.yaml <<CONFIGEOF
listen: :${HY_PORT}

tls:
  cert: /etc/ssl/private/bing.crt
  key: /etc/ssl/private/bing.key

auth:
  type: password
  password: ${HY_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
CONFIGEOF

echo -e "${YELLOW}[5/6] 创建服务...${PLAIN}"
cat > /etc/init.d/hysteria <<'SERVICEEOF'
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
SERVICEEOF
chmod +x /etc/init.d/hysteria
rc-update add hysteria default

echo -e "${YELLOW}[6/6] 启动服务...${PLAIN}"
rc-service hysteria restart || rc-service hysteria start
sleep 2
rc-service hysteria status || cat /var/log/hysteria.log

# === 核心修复：入口IP检测 ===
get_public_ip() {
  local ip=""
  for api in "https://ifconfig.me" "https://ipinfo.io/ip" "https://api.ipify.org" "https://icanhazip.com"; do
    ip=$(curl -4 -s --max-time 5 "$api" 2>/dev/null | tr -d ' \r\n' | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -n1)
    if [ -n "$ip" ]; then echo "$ip"; return; fi
  done
  echo ""
}
get_default_ip() {
  ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -n1
}

if [ -n "$CUSTOM_IP" ]; then
  SERVER_IP="$CUSTOM_IP"
  echo -e "${GREEN}使用手动指定的入口IP: $SERVER_IP${PLAIN}"
else
  PUBLIC_IP=$(get_public_ip)
  LOCAL_IP=$(get_default_ip)
  echo -e "检测到 出口公网IP: ${YELLOW}${PUBLIC_IP:-未知}${PLAIN}"
  echo -e "检测到 本机默认路由IP: ${YELLOW}${LOCAL_IP:-未知}${PLAIN}"
  if [ -n "$PUBLIC_IP" ]; then SERVER_IP="$PUBLIC_IP"; else SERVER_IP="$LOCAL_IP"; fi
  if [ -z "$SERVER_IP" ]; then SERVER_IP="YOUR_SERVER_IP"; fi
  echo -e "${YELLOW}如果 出口IP != 入口IP，请下次用 -i 参数手动指定${PLAIN}"
  echo -e "${YELLOW}示例: curl ... | bash -s -- -p $HY_PORT -w '$HY_PASS' -i 你的入口IP${PLAIN}"
fi

echo ""
echo -e "${GREEN}========== 安装完成 ==========${PLAIN}"
echo -e "端口: ${GREEN}${HY_PORT}/udp${PLAIN} 密码: ${GREEN}${HY_PASS}${PLAIN}"
echo -e "配置: /etc/hysteria/config.yaml"
echo -e "管理: rc-service hysteria restart"
echo ""
echo -e "客户端 YAML:"
echo "server: ${SERVER_IP}:${HY_PORT}"
echo "auth: ${HY_PASS}"
echo "tls:"
echo "  sni: bing.com"
echo "  insecure: true"
echo ""
echo -e "URI:"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Alpine-Hy2-${SERVER_IP}${PLAIN}"
echo ""
echo -e "${YELLOW}记得放行防火墙 UDP ${HY_PORT}${PLAIN}"
echo -e "${YELLOW}如果服务器有多个IP或用了WARP，请确认 ${SERVER_IP} 是你SSH连接的那个IP${PLAIN}"
