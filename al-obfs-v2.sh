#!/bin/sh
# Hysteria 2 Alpine V1.3 - 智能测速优选 SNI 高级防封锁版 (NAT单端口专用)
# 适配: Alpine Linux 3.16+, Karing 客户端完美适配版

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

CUSTOM_PORT=""
CUSTOM_PASSWORD=""
CUSTOM_IP=""
CUSTOM_SNI=""

while getopts "p:w:i:s:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    s) CUSTOM_SNI=$OPTARG ;;
    h) echo "用法: $0 [-p 主端口] [-w 认证密码] [-i 公网IP] [-s 伪装域名]"; exit 0 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

echo -e "${GREEN}=== Hysteria2 Alpine V1.3 智能优选SNI防封锁版 ===${PLAIN}"
echo -e "主机名: $(cat /etc/hostname 2>/dev/null || hostname) | 时间: $(date) | 系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2)"

# ===== [1/5] 基础依赖 - Alpine适配 =====
echo -e "${YELLOW}[1/5] 检查并安装 Alpine 依赖...${PLAIN}"

if ! command -v apk >/dev/null 2>&1; then
  echo -e "${RED}未检测到 apk，不是 Alpine Linux 系统${PLAIN}"; exit 1
fi

apk update -q

# 安装必要依赖包
apk add --no-cache curl openssl iproute2 bind-tools ca-certificates grep coreutils sed awk 2>/dev/null || true
update-ca-certificates 2>/dev/null || true

# ===== [2/5] 参数和路径 =====
echo -e "${YELLOW}[2/5] 初始化参数...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-26169}

# 随机生成混淆密码和认证密码
if command -v openssl >/dev/null 2>&1; then
  HY_OBFS_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  [ -z "$CUSTOM_PASSWORD" ] && HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
else
  HY_OBFS_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
  [ -z "$CUSTOM_PASSWORD" ] && HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
fi
[ -n "$CUSTOM_PASSWORD" ] && HY_PASS=$CUSTOM_PASSWORD
[ -z "$HY_PASS" ] && HY_PASS="Hy2Pass$(date +%s | tail -c 4)"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|armv8*|arm64) HY_ARCH="arm64" ;;
  armv7l|armhf|arm) HY_ARCH="arm" ;;
  *) HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /var/log
chmod 700 /etc/hysteria 2>/dev/null || true

# ===== [3/5] 下载 Hysteria2 =====
echo -e "${YELLOW}[3/5] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
download_ok=0
for i in 1 2 3; do
  if command -v curl >/dev/null 2>&1; then
    if curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL"; then download_ok=1; break; fi
  fi
  sleep 1
done

if [ "$download_ok" != "1" ]; then
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
  done
fi

if [ ! -s /tmp/hysteria ]; then echo -e "${RED}下载失败${PLAIN}"; exit 1; fi
mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

# ===== [4/5] 智能测速优选 SNI 与证书生成 =====
echo -e "${YELLOW}[4/5] 正在智能测速并优选最佳伪装域名 (SNI)...${PLAIN}"

DOMAINS="www.bing.com aws.amazon.com cdn.shopify.com azure.microsoft.com www.cloudflare.com"
BEST_SNI=""
FASTEST_TIME=999.0

if [ -n "$CUSTOM_SNI" ]; then
  BEST_SNI="$CUSTOM_SNI"
  echo -e "${GREEN}✓ 使用用户指定的 SNI: ${BEST_SNI}${PLAIN}"
else
  for domain in $DOMAINS; do
    result=$(curl -4 -o /dev/null -s -w "%{http_code} %{time_total}" --max-time 2 "https://$domain" 2>/dev/null || echo "000 999")
    code=$(echo "$result" | awk '{print $1}')
    time=$(echo "$result" | awk '{print $2}')
    
    if [ "$code" -ge 200 ] && [ "$code" -lt 500 ]; then
      is_faster=$(awk -v t1="$time" -v t2="$FASTEST_TIME" 'BEGIN {print (t1 < t2) ? 1 : 0}')
      if [ "$is_faster" -eq 1 ]; then
        FASTEST_TIME=$time
        BEST_SNI=$domain
      fi
    fi
  done

  if [ -z "$BEST_SNI" ]; then
    BEST_SNI="www.bing.com"
    echo -e "${YELLOW}自动测速未返回有效结果，回退默认使用: ${BEST_SNI}${PLAIN}"
  else
    echo -e "${GREEN}✓ 自动优选成功！最佳 SNI: ${BEST_SNI} (响应耗时: ${FASTEST_TIME}s)${PLAIN}"
  fi
fi

RANDOM_SNI="$BEST_SNI"

if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=${RANDOM_SNI}" -days 3650 2>/dev/null
  chmod 600 /etc/hysteria/key.key
fi

# 写入配置文件
cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}

auth:
  type: password
  password: ${HY_PASS}

obfs:
  type: salamander
  salamander:
    password: ${HY_OBFS_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://${RANDOM_SNI}
    rewriteHost: true

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
EOF

# ===== [5/5] 服务配置 - Alpine OpenRC / Background 兼容 =====
echo -e "${YELLOW}[5/5] 配置并启动服务...${PLAIN}"

cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
pkill -f "hysteria.*config.yaml" || true
sleep 1
if command -v rc-service >/dev/null 2>&1 && rc-status --local 2>/dev/null | grep -q "hysteria"; then
  rc-service hysteria restart
else
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh

if [ -d /etc/init.d ] && command -v openrc >/dev/null 2>&1; then
  cat > /etc/init.d/hysteria << 'INITEOF'
#!/sbin/openrc-run

name="hysteria"
description="Hysteria2 Server (Karing Enhanced)"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria.pid"

depend() {
    need net
    after firewall
}
INITEOF
  chmod +x /etc/init.d/hysteria
  rc-update add hysteria default 2>/dev/null || true
  rc-service hysteria restart 2>/dev/null || rc-service hysteria start 2>/dev/null || true
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true
  sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi

# 输出 Karing 专用配置
SERVER_IP=$CUSTOM_IP
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 5 api.ipify.org || curl -4s --max-time 5 ifconfig.me || echo "你的服务器IP")
fi

echo -e "\n${GREEN}================================================"
echo -e "Hysteria 2 智能优选SNI防封锁节点部署成功！(Alpine版)"
echo -e "================================================${PLAIN}"
echo -e "${CYAN}[Karing 客户端手动填入参数]:${PLAIN}"
echo -e "  - ${YELLOW}服务器地址 (Address):${PLAIN} ${SERVER_IP}"
echo -e "  - ${YELLOW}主端口 (Port):${PLAIN} ${HY_PORT} (请自行填写映射后的外网端口)"
echo -e "  - ${YELLOW}认证密码 (Password):${PLAIN} ${HY_PASS}"
echo -e "  - ${YELLOW}混淆类型 (Obfs Type):${PLAIN} salamander"
echo -e "  - ${YELLOW}混淆密码 (Obfs Password):${PLAIN} ${HY_OBFS_PASS}"
echo -e "  - ${YELLOW}SNI / 伪装域名:${PLAIN} ${RANDOM_SNI}"
echo -e "  - ${YELLOW}允许跳过证书验证 (Insecure):${PLAIN} 开启 (True)"
echo -e "------------------------------------------------"
echo -e "${CYAN}[标准 Hysteria2 节点链接]:${PLAIN}"
echo -e "  hy2://${HY_PASS}@${SERVER_IP}:${HY_PORT}?insecure=1&sni=${RANDOM_SNI}&obfs=salamander&obfs-password=${HY_OBFS_PASS}"
echo -e "================================================"
