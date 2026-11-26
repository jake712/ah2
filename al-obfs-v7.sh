#!/bin/sh
# =========================================================================
# Hysteria 2 (Gecko) + AnyTLS Alpine 同端口終極完美版 - 強制綁定自己內網 IP 版
# 適配: Alpine Linux 3.20/3.21/3.22+, Podman / Docker 容器及原生系統
# 修正: 強制偵測自己內網 IP，排除 wg/tun/docker 隧道，避免 VPS2 走 VPS1 的網
# =========================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

CUSTOM_PORT=""
CUSTOM_IP=""
CUSTOM_EXT_PORT=""

while getopts "p:i:e:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    e) CUSTOM_EXT_PORT=$OPTARG ;;
    h)
      echo "用法: $0 [選項]"
      echo "  -p <端口>   內部監聽端口 (預設隨機高位端口)"
      echo "  -e <端口>   外部端口 (NAT 映射後的外網端口，預設等於 -p)"
      echo "  -i <公網IP> 手動指定伺服器公網 IP"
      exit 0
      ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}錯誤: 請使用 root 權限運行此腳本！${PLAIN}"
  exit 1
fi

echo -e "${GREEN}=== 開始部署 Hysteria 2 (Gecko) + AnyTLS (同端口雙協議 + 綁定自己內網 IP 版) ===${PLAIN}"

# ===== [1/6] 基礎環境與依賴 =====
echo -e "${YELLOW}[1/6] 檢查並配置系統環境...${PLAIN}"
if ! grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
  fi
fi

if ! command -v apk >/dev/null 2>&1; then
  echo -e "${RED}錯誤: 未檢測到 apk 包管理器，本腳本僅支持 Alpine Linux${PLAIN}"
  exit 1
fi

apk update -q
apk add --no-cache curl openssl ca-certificates gawk iproute2 unzip

# ===== [2/6] 強制找「自己的」內網 IP =====
echo -e "${YELLOW}[2/6] 強制偵測自己內網 IP (排除隧道介面)...${PLAIN}"

# 只找實體網卡，排除 lo / docker / veth / br- / wg / tun / tailscale / flannel / cni
# 先找私有 IP (NAT VPS 的情況)
INTERNAL_IP=$(ip -4 -o addr show 2>/dev/null | awk '$2 !~ /^(lo|docker.*|veth.*|br-.*|wg.*|tun.*|tailscale.*|flannel.*|cni.*)/ && $3 == "inet" {print $4}' | cut -d/ -f1 | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -n1)

# 找不到私有 IP，再找任何 Global IP (獨立 IP VPS 的情況)
if [ -z "$INTERNAL_IP" ]; then
  INTERNAL_IP=$(ip -4 -o addr show 2>/dev/null | awk '$2 !~ /^(lo|docker.*|veth.*|br-.*|wg.*|tun.*|tailscale.*|flannel.*|cni.*)/ && $3 == "inet" {print $4}' | cut -d/ -f1 | head -n1)
fi

# 再找不到，用 hostname 兜底
if [ -z "$INTERNAL_IP" ]; then
  INTERNAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi

if [ -z "$INTERNAL_IP" ]; then
  INTERNAL_IP="0.0.0.0"
  echo -e "${YELLOW}警告: 找不到內網 IP，改用 0.0.0.0 監聽${PLAIN}"
  CURL_IF=""
else
  INTERNAL_IF=$(ip -4 -o addr show 2>/dev/null | awk -v ip="$INTERNAL_IP" '$4 ~ ip {print $2; exit}')
  echo -e "${CYAN}✔ 本機內網 IP: ${INTERNAL_IP} (介面: ${INTERNAL_IF})${PLAIN}"
  # 檢查預設路由是不是走隧道，如果是就警告
  DEFAULT_IF=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
  if echo "$DEFAULT_IF" | grep -Eq '^(wg|tun|tailscale)'; then
    echo -e "${RED}⚠ 警告: 預設路由走隧道介面 ${DEFAULT_IF}，流量可能會走 VPS1 的網！${PLAIN}"
    echo -e "${YELLOW}  建議先關閉隧道: wg-quick down wg0，或修正路由${PLAIN}"
  else
    echo -e "${CYAN}✔ 預設路由介面: ${DEFAULT_IF}，正常，走自己的網${PLAIN}"
  fi
  CURL_IF="--interface $INTERNAL_IP"
fi

# ===== [3/6] 端口與密鑰初始化 =====
echo -e "${YELLOW}[3/6] 正在初始化端口與安全密鑰...${PLAIN}"
if [ -n "$CUSTOM_PORT" ]; then
  PORT=$CUSTOM_PORT
  echo -e "${CYAN}✔ 使用用戶指定的內部端口: ${PORT}${PLAIN}"
else
  PORT=$(awk 'BEGIN{srand(); print int(rand()*(55000-10000+1))+10000}')
  echo -e "${CYAN}✔ 未指定端口，已自動生成隨機端口: ${PORT}${PLAIN}"
fi

if [ -n "$CUSTOM_EXT_PORT" ]; then
  LINK_PORT=$CUSTOM_EXT_PORT
  echo -e "${CYAN}✔ 外部端口 (NAT 映射後): ${LINK_PORT}${PLAIN}"
else
  LINK_PORT=$PORT
fi

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

# 監聽地址全部綁死自己的內網 IP
if [ "$INTERNAL_IP" = "0.0.0.0" ]; then
  HY_LISTEN=":${PORT}"
  ATLS_LISTEN=":${PORT}"
else
  HY_LISTEN="${INTERNAL_IP}:${PORT}"
  ATLS_LISTEN="${INTERNAL_IP}:${PORT}"
fi

# ===== [4/6] 下載核心組件並偽裝進程名 =====
echo -e "${YELLOW}[4/6] 下載核心組件並進行特徵偽裝 (強制走自己內網 IP)...${PLAIN}"

# 1. 下載 Hysteria 2
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH_STR}"
rm -f /tmp/hysteria
for url in "$HY_URL" "https://ghfast.top/$HY_URL"; do
  curl -fsSL $CURL_IF --max-time 30 -o /tmp/hysteria "$url" && break
done
[ ! -s /tmp/hysteria ] && { echo -e "${RED}錯誤: Hysteria 2 下載失敗${PLAIN}"; exit 1; }
DISGUISE_HY="systemd-timesyncd"
mv /tmp/hysteria /usr/local/bin/$DISGUISE_HY
chmod +x /usr/local/bin/$DISGUISE_HY

# 2. 下載 AnyTLS
ATLS_API_URL="https://api.github.com/repos/anytls/anytls-go/releases/latest"
ATLS_ZIP_URL=$(curl -s $CURL_IF --max-time 10 "$ATLS_API_URL" | grep "browser_download_url.*linux_${ARCH_STR}\.zip" | cut -d '"' -f 4 | head -n 1)

INSTALL_ATLS=0
if [ -n "$ATLS_ZIP_URL" ]; then
  rm -f /tmp/anytls.zip
  for url in "$ATLS_ZIP_URL" "https://ghfast.top/$ATLS_ZIP_URL"; do
    if curl -fsSL $CURL_IF --max-time 30 -o /tmp/anytls.zip "$url"; then
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
  echo -e "${YELLOW}提示: AnyTLS 核心未能成功下載，將僅部署 Hysteria 2${PLAIN}"
fi

# ===== [5/6] 優選 SNI 與生成配置 =====
echo -e "${YELLOW}[5/6] 智能優選 SNI 並生成憑證與配置 (強制走自己內網 IP)...${PLAIN}"
SNI_CANDIDATES="www.【entity-amd¦canonical_name=AMD】.com www.【entity-apple¦canonical_name=Apple】.com pypi.org www.【entity-samsung¦canonical_name=Samsung】.com www.【entity-sony¦canonical_name=Sony】.com www.【entity-oracle¦canonical_name=Oracle】.com www.deb.debian.org"
OPTIMIZED_SNI="www.bing.com"
LOWEST_LATENCY=9999
for domain in $SNI_CANDIDATES; do
  latency=$(curl -o /dev/null -s -w '%{time_connect}\n' $CURL_IF --connect-timeout 2 -m 3 "https://$domain" 2>/dev/null || echo "999")
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

# 寫入 Hysteria 2 YAML 配置 (Gecko 混淆 + 綁定自己內網 IP + 出站綁定)
cat > /etc/hysteria/config.yaml <<EOF
listen: ${HY_LISTEN}
auth:
  type: password
  password: ${HY_PASS}
obfs:
  type: gecko
  gecko:
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

# 只有找到內網 IP 時才加出站綁定，強制流量走自己的網，不走 VPS1 的隧道
if [ "$INTERNAL_IP" != "0.0.0.0" ]; then
  cat >> /etc/hysteria/config.yaml <<EOF
outbounds:
    - name: direct
    type: direct
    direct:
      mode: 64
      bindIPv4: ${INTERNAL_IP}
EOF
fi

# ===== [6/6] 啟動服務與輸出結果 =====
echo -e "${YELLOW}[6/6] 啟動服務進程...${PLAIN}"
pkill -x "$DISGUISE_HY" 2>/dev/null || true
[ "$INSTALL_ATLS" = "1" ] && { pkill -x "$DISGUISE_ATLS" 2>/dev/null || true; }
sleep 1

# 啟動 Hysteria 2
nohup /usr/local/bin/$DISGUISE_HY server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &

# 啟動 AnyTLS (綁定自己內網 IP)
if [ "$INSTALL_ATLS" = "1" ]; then
  nohup /usr/local/bin/$DISGUISE_ATLS -l "${ATLS_LISTEN}" -p "${ATLS_PASS}" > /var/log/anytls.log 2>&1 &
fi

# 獲取公網 IP (強制走自己內網 IP 去抓，不走 VPS1)
SERVER_IP="$CUSTOM_IP"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s $CURL_IF --max-time 4 api.ipify.org 2>/dev/null || true)
  if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -4s --max-time 4 api.ipify.org 2>/dev/null || true)
  fi
  if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -4s $CURL_IF --max-time 4 ifconfig.me 2>/dev/null || true)
  fi
  if [ -z "$SERVER_IP" ]; then
    SERVER_IP="YOUR_SERVER_IP"
  fi
fi

echo -e "\n${GREEN}================================================================${PLAIN}"
echo -e "${GREEN}🎉 同端口雙協議 (Gecko 混淆 + 綁定自己內網 IP) 部署成功！${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e " 🏠 本機內網 IP (Internal) : ${CYAN}${INTERNAL_IP}${PLAIN}"
echo -e " 📍 伺服器地址 (Address) : ${CYAN}${SERVER_IP}${PLAIN}"
echo -e " 🔢 內部監聽端口 (Internal) : ${CYAN}${PORT} (TCP & UDP)${PLAIN}"
echo -e " 🌐 外部訪問端口 (External) : ${CYAN}${LINK_PORT} (NAT 映射後)${PLAIN}"
echo -e " 🌐 共享偽裝域名 (SNI)   : ${CYAN}${OPTIMIZED_SNI}${PLAIN}"
echo -e "----------------------------------------------------------------"
echo -e " [1] Hysteria 2 配置信息 (Gecko)"
echo -e "   - 認證密碼 : ${CYAN}${HY_PASS}${PLAIN}"
echo -e "   - 混淆類型 : ${CYAN}gecko${PLAIN}"
echo -e "   - 混淆密碼 : ${CYAN}${HY_OBFS_PASS}${PLAIN}"
echo -e "----------------------------------------------------------------"
if [ "$INSTALL_ATLS" = "1" ]; then
  echo -e " [2] AnyTLS 配置信息"
  echo -e "   - 認證密碼 : ${CYAN}${ATLS_PASS}${PLAIN}"
  echo -e "----------------------------------------------------------------"
fi
echo -e "${YELLOW}[Hysteria 2 直連連結]:${PLAIN}"
echo -e "${CYAN}hy2://${HY_PASS}@${SERVER_IP}:${LINK_PORT}?insecure=1&sni=${OPTIMIZED_SNI}&obfs=gecko&obfs-password=${HY_OBFS_PASS}#Hy2-Gecko-SharedPort${PLAIN}"
if [ "$INSTALL_ATLS" = "1" ]; then
  echo -e "\n${YELLOW}[AnyTLS 直連連結]:${PLAIN}"
  echo -e "${CYAN}anytls://${ATLS_PASS}@${SERVER_IP}:${LINK_PORT}?sni=${OPTIMIZED_SNI}&insecure=1#AnyTLS-SharedPort${PLAIN}"
fi
echo -e "${GREEN}================================================================${PLAIN}"
