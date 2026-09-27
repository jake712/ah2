#!/bin/bash
# Hysteria 2 一键安装脚本 for Alpine Linux V2 - 防墙/防HTML版
# 用法: ./hysteria2-alpine-install-v2.sh -p 56764 -w "你的密码"
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

DEFAULT_PORT=56764

while getopts "p:w:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    h) echo "用法: $0 [-p 端口] [-w 密码]"; exit 0 ;;
  esac
done

CUSTOM_PORT=${CUSTOM_PORT:-${PORT:-}}
CUSTOM_PASSWORD=${CUSTOM_PASSWORD:-${PASSWORD:-}}

if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}请用 root 运行${PLAIN}"; exit 1
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
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; echo
}

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

echo -e "${GREEN}=== 开始安装 Hysteria 2 ===${PLAIN}"
echo -e "端口: $HY_PORT  密码: $HY_PASS"

echo -e "${YELLOW}[1/6] 安装依赖...${PLAIN}"
apk update
apk add --no-cache bash curl wget openssl tar iproute2 file

mkdir -p /usr/local/bin
mkdir -p /etc/ssl/private
mkdir -p /etc/hysteria
mkdir -p /var/log

# 2. 核心修复：多镜像下载 + ELF校验
echo -e "${YELLOW}[2/6] 下载 Hysteria 2 (自动重试多镜像)...${PLAIN}"
ARCH_TYPE=$(get_arch)
BIN_NAME="hysteria-linux-${ARCH_TYPE}"
DEST="/usr/local/bin/hysteria"

URLS=(
  "https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
  "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
  "https://ghproxy.com/https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
  "https://mirror.ghproxy.com/https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
  "https://gh-proxy.com/https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
)

download_success=0
for URL in "${URLS[@]}"; do
  echo -e "  尝试: $URL"
  rm -f "$DEST" /tmp/hy.download
  # 用 curl -L 跟随跳转，失败不直接退出
  if curl -fL --connect-timeout 10 --max-time 60 -o /tmp/hy.download "$URL" 2>&1; then
    # 检查是不是 HTML
    if head -c 20 /tmp/hy.download | grep -qi "<!DOCTYPE\|<html"; then
      echo -e "${RED}  -> 下载到的是 HTML 网页，丢弃重试${PLAIN}"
      continue
    fi
    # 检查是不是 ELF 可执行文件
    if ! head -c 4 /tmp/hy.download | grep -q $'\x7fELF'; then
       # 可能是文本错误
       echo "  -> 文件头不是 ELF，内容:"
       head -c 200 /tmp/hy.download
       echo ""
       continue
    fi
    # 检查大小 > 2MB
    SIZE=$(wc -c < /tmp/hy.download)
    if [ "$SIZE" -lt 2000000 ]; then
      echo -e "${RED}  -> 文件太小 ($SIZE bytes)，可能下载不完整${PLAIN}"
      continue
    fi
    mv /tmp/hy.download "$DEST"
    chmod +x "$DEST"
    download_success=1
    echo -e "${GREEN}  -> 下载成功 ($SIZE bytes)${PLAIN}"
    break
  else
    echo -e "${RED}  -> 下载失败，尝试下一个镜像${PLAIN}"
  fi
done

if [ "$download_success" -ne 1 ]; then
  echo -e "${RED}所有镜像都下载失败！${PLAIN}"
  echo "请手动尝试："
  echo "1. 检查网络： ping github.com"
  echo "2. 手动下载后上传到 /usr/local/bin/hysteria"
  echo "3. 或使用: wget -O $DEST https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
  exit 1
fi

"$DEST" version

# 3. 证书
echo -e "${YELLOW}[3/6] 生成 TLS 证书...${PLAIN}"
openssl ecparam -genkey -name prime256v1 -noout -out /etc/ssl/private/bing.key
openssl req -new -x509 -nodes -key /etc/ssl/private/bing.key -out /etc/ssl/private/bing.crt -days 3650 -subj "/CN=bing.com"
chmod 600 /etc/ssl/private/bing.key
chmod 644 /etc/ssl/private/bing.crt

# 4. 配置文件
echo -e "${YELLOW}[4/6] 生成配置文件...${PLAIN}"
cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}

tls:
  cert: /etc/ssl/private/bing.crt
  key: /etc/ssl/private/bing.key

auth:
  type: password
  password: "${HY_PASS}"

ignoreClientBandwidth: true

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
EOF

# 5. OpenRC 服务
echo -e "${YELLOW}[5/6] 创建服务...${PLAIN}"
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

# 6. 启动
echo -e "${YELLOW}[6/6] 启动服务...${PLAIN}"
rc-service hysteria restart || rc-service hysteria start
sleep 2
rc-service hysteria status || cat /var/log/hysteria.log

SERVER_IP=$(curl -4 -s --max-time 5 https://ifconfig.me || curl -4 -s --max-time 5 https://ipinfo.io/ip || echo "YOUR_SERVER_IP")

echo ""
echo -e "${GREEN}========== 安装完成 ==========${PLAIN}"
echo -e "端口: ${GREEN}${HY_PORT}/udp${PLAIN}  密码: ${GREEN}${HY_PASS}${PLAIN}"
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
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Alpine-Hy2${PLAIN}"
echo ""
echo -e "${YELLOW}记得放行防火墙 UDP ${HY_PORT}${PLAIN}"
