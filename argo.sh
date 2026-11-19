#!/bin/sh
# =========================================================================
# Hysteria 2 + AnyTLS + Cloudflare Argo Tunnel Debian 部署脚本
# 适配: Debian 11/12+ (AMD64 / ARM64)
# =========================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

CUSTOM_PORT=""
CUSTOM_IP=""
ENABLE_ARGO=0
ARGO_TOKEN=""

while getopts "p:i:ak:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    a) ENABLE_ARGO=1 ;;
    k) ARGO_TOKEN=$OPTARG; ENABLE_ARGO=1 ;;
    h)
      echo "用法: $0 [选项]"
      echo "  -p <端口>       自定义监听端口 (默认随机高位端口)"
      echo "  -i <公网IP>     手动指定服务器公网 IP"
      echo "  -a              启用 Cloudflare Argo 临时隧道 (trycloudflare.com)"
      echo "  -k <ARGO_TOKEN> 使用指定的 Cloudflare Tunnel Token 启用固定隧道"
      exit 0
      ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
  exit 1
fi

echo -e "${GREEN}=== 开始部署 Hysteria 2 + AnyTLS (+ Argo Tunnel) ===${PLAIN}"

# ===== [1/6] 基础环境与依赖 =====
echo -e "${YELLOW}[1/6] 检查并配置系统环境...${PLAIN}"
if ! grep -q "nameserver" /etc/resolv.conf 2>/dev/null; then
  echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo -e "${RED}错误: 未检测到 apt-get 包管理器，本脚本仅支持 Debian / Ubuntu 系统${PLAIN}"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates gawk iproute2 unzip >/dev/null 2>&1

# ===== [2/6] 端口与密钥初始化 =====
echo -e "${YELLOW}[2/6] 正在初始化端口与安全密钥...${PLAIN}"
if [ -n "$CUSTOM_PORT" ]; then
  PORT=$CUSTOM_PORT
  echo -e "${CYAN}✔ 使用用户指定的端口: ${PORT}${PLAIN}"
else
  PORT=$(awk 'BEGIN{srand(); print int(rand()*(55000-10000+1))+10000}')
  echo -e "${CYAN}✔ 未指定端口，已自动生成随机端口: ${PORT}${PLAIN}"
fi

# Argo 本地反代目标端口（默认指向同端口或本地回环端口）
ARGO_LOCAL_PORT="${PORT}"

HY_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
HY_OBFS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
ATLS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH_STR="amd64" ;;
  aarch64|arm64) ARCH_STR="arm64" ;;
  *) ARCH_STR="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /var/log
chmod 700 /etc/hysteria

# ===== [3/6] 下载核心组件并伪装进程名 =====
echo -e "${YELLOW}[3/6] 下载核心组件并进行特征伪装...${PLAIN}"

# 1. 下载 Hysteria 2
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH_STR}"
rm -f /tmp/hysteria
for url in "$HY_URL" "https://ghfast.top/$HY_URL"; do
  curl -fsSL --max-time 30 -o /tmp/hysteria "$url" && break
done
[ ! -s /tmp/hysteria ] && { echo -e "${RED}错误: Hysteria 2 下载失败${PLAIN}"; exit 1; }
DISGUISE_HY="systemd-timesyncd"
mv /tmp/hysteria /usr/local/bin/$DISGUISE_HY
chmod +x /usr/local/bin/$DISGUISE_HY

# 2. 下载 AnyTLS
ATLS_API_URL="https://api.github.com/repos/anytls/anytls-go/releases/latest"
ATLS_ZIP_URL=$(curl -s --max-time 10 "$ATLS_API_URL" | grep "browser_download_url.*linux_${ARCH_STR}\.zip" | cut -d '"' -f 4 | head -n 1)

INSTALL_ATLS=0
if [ -n "$ATLS_ZIP_URL" ]; then
  rm -f /tmp/anytls.zip
  for url in "$ATLS_ZIP_URL" "https://ghfast.top/$ATLS_ZIP_URL"; do
    if curl -fsSL --max-time 30 -o /tmp/anytls.zip "$url"; then
      break
    fi
  done

  if [ -s /tmp/anytls.zip ]; then
    unzip -qo /tmp/anytls.zip -d /tmp/
    ATLS_BIN=$(find /tmp -maxdepth 1 -type f \( -name "anytls-server" -o -name "anytls" \) | head -n 1)
    if [ -n "$ATLS_BIN" ] && [ -s "$ATLS_BIN" ]; then
      INSTALL_ATLS=1
      DISGUISE_ATLS="systemd-networkd"
      mv "$ATLS_BIN" /usr/local/bin/$DISGUISE_ATLS
      chmod +x /usr/local/bin/$DISGUISE_ATLS
    fi
  fi
fi

if [ "$INSTALL_ATLS" != "1" ]; then
  echo -e "${YELLOW}提示: AnyTLS 核心未能成功下载，将仅部署 Hysteria 2${PLAIN}"
fi

# 3. 下载 cloudflared (Argo Tunnel)
INSTALL_ARGO=0
DISGUISE_ARGO="systemd-journald"
if [ "$ENABLE_ARGO" = "1" ]; then
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_STR}"
  rm -f /tmp/cloudflared
  for url in "$CF_URL" "https://ghfast.top/$CF_URL"; do
    if curl -fsSL --max-time 40 -o /tmp/cloudflared "$url" && [ -s /tmp/cloudflared ]; then
      INSTALL_ARGO=1
      break
    fi
  done

  if [ "$INSTALL_ARGO" = "1" ]; then
    mv /tmp/cloudflared /usr/local/bin/$DISGUISE_ARGO
    chmod +x /usr/local/bin/$DISGUISE_ARGO
  else
    echo -e "${YELLOW}提示: cloudflared 下载失败，跳过 Argo 隧道启动${PLAIN}"
  fi
fi

# ===== [4/6] 优选 SNI 与生成配置 =====
echo -e "${YELLOW}[4/6] 智能优选 SNI 并生成证书与配置...${PLAIN}"
SNI_CANDIDATES="www.bing.com www.apple.com www.cloudflare.com"
OPTIMIZED_SNI="www.bing.com"
LOWEST_LATENCY=9999
for domain in $SNI_CANDIDATES; do
  latency=$(curl -o /dev/null -s -w '%{time_connect}\n' --connect-timeout 2 -m 3 "https://$domain" 2>/dev/null || echo "999")
  is_better=$(awk -v l="$latency" -v min="$LOWEST_LATENCY" 'BEGIN {if (l > 0 && l < min) print 1; else print 0}')
  if [ "$is_better" = "1" ]; then
    LOWEST_LATENCY=$latency
    OPTIMIZED_SNI=$domain
  fi
done

rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null
openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=${OPTIMIZED_SNI}" -days 3650 2>/dev/null
chmod 600 /etc/hysteria/key.key

cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}
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
    url: https://${OPTIMIZED_SNI}
    rewriteHost: true
tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
EOF

# ===== [5/6] 启动服务与 Argo 隧道 =====
echo -e "${YELLOW}[5/6] 启动服务进程...${PLAIN}"
pkill -x "$DISGUISE_HY" 2>/dev/null || true
[ "$INSTALL_ATLS" = "1" ] && { pkill -x "$DISGUISE_ATLS" 2>/dev/null || true; }
[ "$INSTALL_ARGO" = "1" ] && { pkill -x "$DISGUISE_ARGO" 2>/dev/null || true; }
sleep 1

nohup /usr/local/bin/$DISGUISE_HY server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &

if [ "$INSTALL_ATLS" = "1" ]; then
  nohup /usr/local/bin/$DISGUISE_ATLS -l ":${PORT}" -p "${ATLS_PASS}" > /var/log/anytls.log 2>&1 &
fi

ARGO_DOMAIN=""
if [ "$INSTALL_ARGO" = "1" ]; then
  rm -f /var/log/argo.log
  if [ -n "$ARGO_TOKEN" ]; then
    # 固定 Tunnel（需在 Cloudflare Zero Trust 后台将 Public Hostname 指向 http://127.0.0.1:${ARGO_LOCAL_PORT} 或 https://127.0.0.1:${ARGO_LOCAL_PORT}）
    nohup /usr/local/bin/$DISGUISE_ARGO tunnel --no-autoupdate run --token "$ARGO_TOKEN" > /var/log/argo.log 2>&1 &
    ARGO_DOMAIN="(由 Cloudflare Zero Trust 控制台绑定域名)"
  else
    # 免登录临时 Argo 隧道
    nohup /usr/local/bin/$DISGUISE_ARGO tunnel --no-autoupdate --url "http://127.0.0.1:${ARGO_LOCAL_PORT}" > /var/log/argo.log 2>&1 &
    for _ in $(seq 1 15); do
      sleep 1
      ARGO_DOMAIN=$(grep -Eo 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' /var/log/argo.log | head -n 1 | sed 's#https://##')
      [ -n "$ARGO_DOMAIN" ] && break
    done
  fi
fi

# ===== [6/6] 输出结果 =====
echo -e "${YELLOW}[6/6] 汇总连接信息...${PLAIN}"
SERVER_IP="$CUSTOM_IP"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 4 api.ipify.org || curl -4s --max-time 4 ifconfig.me || echo "YOUR_SERVER_IP")
fi

echo -e "\n${GREEN}================================================================${PLAIN}"
echo -e "${GREEN}🎉 部署完成！${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e " 📍 直连服务器 IP (IP)   : ${CYAN}${SERVER_IP}${PLAIN}"
echo -e " 🔢 共用监听端口 (Port)  : ${CYAN}${PORT} (TCP & UDP)${PLAIN}"
echo -e " 🌐 共享伪装域名 (SNI)   : ${CYAN}${OPTIMIZED_SNI}${PLAIN}"
if [ "$INSTALL_ARGO" = "1" ]; then
  echo -e " 🚇 Argo 隧道地址        : ${CYAN}${ARGO_DOMAIN:-生成中，请查看 /var/log/argo.log}${PLAIN}"
fi
echo -e "----------------------------------------------------------------"
echo -e " [1] Hysteria 2 配置信息 (UDP QUIC，建议走直连或外部中转)"
echo -e "    - 认证密码 : ${CYAN}${HY_PASS}${PLAIN}"
echo -e "    - 混淆密码 : ${CYAN}${HY_OBFS_PASS}${PLAIN}"
echo -e "----------------------------------------------------------------"
if [ "$INSTALL_ATLS" = "1" ]; then
  echo -e " [2] AnyTLS 配置信息"
  echo -e "    - 认证密码 : ${CYAN}${ATLS_PASS}${PLAIN}"
  echo -e "----------------------------------------------------------------"
fi
echo -e "${YELLOW}[Hysteria 2 直连链接]:${PLAIN}"
echo -e "${CYAN}hy2://${HY_PASS}@${SERVER_IP}:${PORT}?insecure=1&sni=${OPTIMIZED_SNI}&obfs=salamander&obfs-password=${HY_OBFS_PASS}#Hy2-Direct${PLAIN}"
if [ "$INSTALL_ATLS" = "1" ]; then
  echo -e "\n${YELLOW}[AnyTLS 直连链接]:${PLAIN}"
  echo -e "${CYAN}anytls://${ATLS_PASS}@${SERVER_IP}:${PORT}?sni=${OPTIMIZED_SNI}&insecure=1#AnyTLS-Direct${PLAIN}"
fi
echo -e "${GREEN}================================================================${PLAIN}"
