#!/bin/sh
# =========================================================================
# Hysteria 2 (Gecko, UDP) + VLESS-REALITY (Xray, TCP) —— Alpine 同端口双协议完整版
#   · Hysteria 2 走 UDP:${PORT} (obfs: gecko, v2.9.2+)
#   · VLESS-REALITY 走 TCP:${PORT} (flow: xtls-rprx-vision)
#   · 兩者協議棧不同，TCP/UDP 同用一個埠號互不衝突
# 适配: Alpine 3.18+ / Podman / Docker / 原生系統
# =========================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

CUSTOM_PORT=""
CUSTOM_IP=""
CUSTOM_SNI=""
HY_TAG="${HY_TAG:-latest}"

while getopts "p:i:s:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    s) CUSTOM_SNI=$OPTARG ;;
    h)
      echo "用法: $0 [选项]"
      echo "  -p <端口>     自定义监听端口 (TCP+UDP 同号, 默认随机高位端口)"
      echo "  -i <公网IP>   手动指定服务器公网 IP"
      echo "  -s <域名>     手动指定 REALITY/SNI 伪装域名"
      exit 0
      ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
  exit 1
fi

echo -e "${GREEN}=== 开始部署 Hysteria 2 (Gecko/UDP) + VLESS-REALITY (Xray/TCP) 同端口双协议 ===${PLAIN}"

# ===== [1/7] 基础环境与依赖 =====
echo -e "${YELLOW}[1/7] 检查并配置系统环境...${PLAIN}"
if ! command -v apk >/dev/null 2>&1; then
  echo -e "${RED}错误: 未检测到 apk 包管理器，本脚本仅支持 Alpine Linux${PLAIN}"
  exit 1
fi
if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
fi
apk update -q
apk add --no-cache curl openssl ca-certificates gawk iproute2 unzip

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)      XRAY_PKG="Xray-linux-64.zip";     HY_BIN="hysteria-linux-amd64" ;;
  aarch64|arm64)     XRAY_PKG="Xray-linux-arm64-v8a.zip"; HY_BIN="hysteria-linux-arm64" ;;
  armv7l|armv7)      XRAY_PKG="Xray-linux-arm32-v7a.zip"; HY_BIN="hysteria-linux-arm" ;;
  *) echo -e "${RED}错误: 不支持的架构 ${ARCH}${PLAIN}"; exit 1 ;;
esac

mkdir -p /etc/hysteria /usr/local/etc/xray /usr/local/bin /var/log/xray
chmod 700 /etc/hysteria /usr/local/etc/xray

# ===== [2/7] 端口选择与占用检测 =====
echo -e "${YELLOW}[2/7] 正在初始化监听端口...${PLAIN}"
port_busy() {
  ss -lntu 2>/dev/null | awk -v p="$1" '$4 ~ (":" p "$") { f=1 } END { exit !f }'
}
if [ -n "$CUSTOM_PORT" ]; then
  PORT=$CUSTOM_PORT
  if port_busy "$PORT"; then
    echo -e "${RED}错误: 端口 ${PORT} 已被占用 (TCP 或 UDP)，请更换${PLAIN}"; exit 1
  fi
  echo -e "${CYAN}✔ 使用用户指定端口: ${PORT} (TCP+UDP 同号)${PLAIN}"
else
  PORT=""
  i=0
  while [ $i -lt 30 ]; do
    PORT=$(awk 'BEGIN{srand(); print int(rand()*(55000-10000+1))+10000}')
    port_busy "$PORT" || break
    PORT=""; i=$((i+1))
  done
  if [ -z "$PORT" ]; then echo -e "${RED}错误: 无法找到可用端口${PLAIN}"; exit 1; fi
  echo -e "${CYAN}✔ 已自动生成随机端口: ${PORT} (TCP+UDP 同号)${PLAIN}"
fi

# ===== [3/7] 下载核心组件并伪装进程名 =====
echo -e "${YELLOW}[3/7] 下载 Hysteria 2 与 Xray-core...${PLAIN}"
dl() { # dl <原始URL> <输出文件>
  for u in "$1" "https://ghfast.top/$1" "https://gh-proxy.com/$1"; do
    curl -fsSL --connect-timeout 10 --max-time 90 -o "$2" "$u" && return 0
  done
  return 1
}

DISGUISE_HY="systemd-timesyncd"
DISGUISE_XRAY="systemd-journald"

# 1) 下载 Hysteria 2 (tag 可覆寫, 建議最新 >= v2.9.2 以支援 gecko)
HY_VER_TAG="${HY_TAG:-latest}"
if [ "$HY_VER_TAG" = "latest" ]; then
  HY_URL="https://github.com/apernet/hysteria/releases/latest/download/${HY_BIN}"
else
  HY_URL="https://github.com/apernet/hysteria/releases/download/${HY_VER_TAG}/${HY_BIN}"
fi
rm -f /tmp/hysteria
if ! dl "$HY_URL" /tmp/hysteria || [ ! -s /tmp/hysteria ]; then
  echo -e "${RED}错误: Hysteria 2 下载失败${PLAIN}"; exit 1
fi
mv /tmp/hysteria /usr/local/bin/$DISGUISE_HY
chmod +x /usr/local/bin/$DISGUISE_HY
HY_BIN_PATH="/usr/local/bin/$DISGUISE_HY"

# 2) 下载 Xray-core
XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_PKG}"
rm -f /tmp/xray.zip; rm -rf /tmp/xray_pkg; rm -f /tmp/xray
if ! dl "$XRAY_URL" /tmp/xray.zip; then
  echo -e "${RED}错误: Xray-core 下载失败${PLAIN}"; exit 1
fi
unzip -qo /tmp/xray.zip -d /tmp/xray_pkg
XRAY_BIN=$(find /tmp/xray_pkg -maxdepth 2 -type f -name "xray" | head -n 1)
if [ -z "$XRAY_BIN" ] || [ ! -s "$XRAY_BIN" ]; then
  echo -e "${RED}错误: Xray 解压失败${PLAIN}"; exit 1
fi
mv "$XRAY_BIN" /usr/local/bin/$DISGUISE_XRAY
chmod +x /usr/local/bin/$DISGUISE_XRAY
XRAY_BIN_PATH="/usr/local/bin/$DISGUISE_XRAY"
rm -rf /tmp/xray_pkg /tmp/xray.zip

# ===== [4/7] 版本检测: Hysteria 2 >= v2.9.2 才支援 gecko; 优选 REALITY 目标 SNI =====
echo -e "${YELLOW}[4/7] 检测 Hysteria 版本并优选 REALITY/SNI 目标...${PLAIN}"
HY_VER=$("$HY_BIN_PATH" version 2>/dev/null | awk '/^Version/{print $2}' | sed 's/.*v//')
echo -e "  当前 Hysteria 版本: ${HY_VER:-unknown}"
OBFS_TYPE="gecko"
if [ -n "$HY_VER" ]; then
  if ! awk -v v="$HY_VER" 'BEGIN{
        split(v,a,"."); maj=a[1]+0; min=a[2]+0; pat=a[3]+0;
        if (maj>2) exit 0; if (maj<2) exit 1;
        if (min>9) exit 0; if (min<9) exit 1;
        if (pat>=2) exit 0; exit 1;
      }'; then
    OBFS_TYPE="salamander"
    echo -e "${YELLOW}提示: 检测到 Hysteria v${HY_VER} 未支援 gecko, 自动回退为 salamander${PLAIN}"
  fi
fi
echo -e "  ✔ 当前混淆类型: ${OBFS_TYPE}"

if [ -n "$CUSTOM_SNI" ]; then
  OPTIMIZED_SNI="$CUSTOM_SNI"
  echo -e "${CYAN}✔ 使用指定伪装域名: ${OPTIMIZED_SNI}${PLAIN}"
else
  SNI_CANDIDATES="www.microsoft.com www.apple.com dl.google.com addons.mozilla.org gateway.icloud.com www.cloudflare.com"
  OPTIMIZED_SNI=""; BEST=9999
  for domain in $SNI_CANDIDATES; do
    # REALITY 硬性要求: 目标站点须支持 TLS 1.3
    ver=$(openssl s_client -connect "$domain:443" -servername "$domain" -tls1_3 </dev/null 2>/dev/null | grep -m1 "Protocol *:" | awk '{print $3}')
    [ "$ver" = "TLSv1.3" ] || continue
    lat=$(curl -o /dev/null -s -w '%{time_connect}' --connect-timeout 2 -m 4 "https://$domain" 2>/dev/null)
    case "$lat" in ''|*[!0-9.]*) continue ;; esac
    if [ $(awk -v l="$lat" -v m="$BEST" 'BEGIN{exit !(l>0 && l<m)}') = "0" ]; then
      BEST=$lat; OPTIMIZED_SNI=$domain
    fi
  done
  if [ -z "$OPTIMIZED_SNI" ]; then OPTIMIZED_SNI="www.microsoft.com"; fi
  echo -e "${CYAN}✔ 优选 REALITY/SNI 目标: ${OPTIMIZED_SNI} (${BEST}s)${PLAIN}"
fi

# ===== [5/7] 生成证书、密钥与双协议配置文件 =====
echo -e "${YELLOW}[5/7] 生成 Hysteria 2 证书、Xray REALITY 密钥并写入配置...${PLAIN}"

rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null
openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt \
  -subj "/CN=${OPTIMIZED_SNI}" -days 3650 2>/dev/null
chmod 600 /etc/hysteria/key.key

HY_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
HY_OBFS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

VLESS_UUID=$("$XRAY_BIN_PATH" uuid 2>/dev/null)
SHORT_ID=$(openssl rand -hex 8)
X25519_OUT=$("$XRAY_BIN_PATH" x25519 2>/dev/null)
REALITY_PRIV=$(printf '%s\n' "$X25519_OUT" | awk -F':[ \t]*' 'tolower($1) ~ /private/ {print $2; exit}')
REALITY_PUB=$(printf '%s\n' "$X25519_OUT" | awk -F':[ \t]*' 'tolower($1) ~ /(public|password)/ {print $2; exit}')
if [ -z "$REALITY_PRIV" ] || [ -z "$REALITY_PUB" ]; then
  echo -e "${RED}错误: REALITY 密钥生成失败 (xray x25519 输出异常)${PLAIN}"
  echo "$X25519_OUT"; exit 1
fi

# ---------- Hysteria 2 (UDP) ----------
cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}
auth:
  type: password
  password: ${HY_PASS}
obfs:
  type: ${OBFS_TYPE}
  ${OBFS_TYPE}:
    password: ${HY_OBFS_PASS}
masquerade:
  type: proxy
  proxy:
    url: https://${OPTIMIZED_SNI}
    rewriteHost: true
tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
ignoreClientBandwidth: true
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF

# ---------- Xray VLESS-REALITY (TCP) ----------
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning", "error": "/var/log/xray/error.log" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${VLESS_UUID}", "email": "reality@local", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "tlsSettings": {
          "serverName": "${OPTIMIZED_SNI}",
          "allowInsecure": false,
          "fingerprint": "chrome",
          "alpn": [ "http/1.1" ],
          "fingerprintChromeFallback": [ "chrome" ]
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${OPTIMIZED_SNI}:443",
          "xver": 0,
          "serverNames": [ "${OPTIMIZED_SNI}" ],
          "privateKey": "${REALITY_PRIV}",
          "shortIds": [ "${SHORT_ID}" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": [ "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15" ], "outboundTag": "blocked" }
    ]
  }
}
EOF

if ! "$XRAY_BIN_PATH" run -test -c /usr/local/etc/xray/config.json >/dev/null 2>&1; then
  if ! "$XRAY_BIN_PATH" -test -c /usr/local/etc/xray/config.json >/dev/null 2>&1; then
    echo -e "${RED}错误: Xray 配置校验未通过${PLAIN}"
    "$XRAY_BIN_PATH" run -test -c /usr/local/etc/xray/config.json || true
    exit 1
  fi
fi
echo -e "${CYAN}✔ Xray 配置校验通过${PLAIN}"

# ===== [6/7] 启动服务 =====
echo -e "${YELLOW}[6/7] 启动服务进程...${PLAIN}"
pkill -f "/usr/local/bin/$DISGUISE_HY"  2>/dev/null || true
pkill -f "/usr/local/bin/$DISGUISE_XRAY" 2>/dev/null || true
sleep 1

USE_OPENRC=0
if [ -x /sbin/openrc-run ] && [ -d /run/openrc ] && [ -d /etc/runlevels ]; then USE_OPENRC=1; fi

if [ "$USE_OPENRC" = "1" ]; then
  cat > /etc/init.d/hy2 <<'EOF'
#!/sbin/openrc-run
name="hy2"
command="/usr/local/bin/${DISGUISE_HY}"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hy2.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
GOGC=20
EOF
  cat > /etc/init.d/xray-reality <<'EOF'
#!/sbin/openrc-run
name="xray-reality"
command="/usr/local/bin/${DISGUISE_XRAY}"
command_args="run -c /usr/local/etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"
GOGC=20
EOF
  chmod +x /etc/init.d/hy2 /etc/init.d/xray-reality
  rc-update add hy2 default >/dev/null 2>&1 || true
  rc-update add xray-reality default >/dev/null 2>&1 || true
  rc-service hy2 restart >/dev/null 2>&1 || rc-service hy2 start
  rc-service xray-reality restart >/dev/null 2>&1 || rc-service xray-reality start
else
  GOGC=20 nohup /usr/local/bin/$DISGUISE_HY server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
  GOGC=20 nohup /usr/local/bin/$DISGUISE_XRAY run -c /usr/local/etc/xray/config.json > /var/log/xray/error.log 2>&1 &
fi

sleep 2
HY_OK="✘"; XR_OK="✘"
pgrep -f "/usr/local/bin/$DISGUISE_HY" >/dev/null 2>&1 && HY_OK="✔"
pgrep -f "/usr/local/bin/$DISGUISE_XRAY" >/dev/null 2>&1 && XR_OK="✔"

# ===== [7/7] 获取公网 IP 與輸出結果 =====
SERVER_IP="$CUSTOM_IP"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 4 api.ipify.org || curl -4s --max-time 4 ifconfig.me || echo "YOUR_SERVER_IP")
fi

echo -e "\n${GREEN}================================================================${PLAIN}"
echo -e "${GREEN}🎉 同端口双协议部署完成：Hysteria2(Gecko/UDP) + VLESS-REALITY(Xray/TCP)${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e " 📍 服务器地址 (Address) : ${CYAN}${SERVER_IP}${PLAIN}"
echo -e " 🔢 共用端口 (Port)      : ${CYAN}${PORT}  (Hy2=UDP / REALITY=TCP)${PLAIN}"
echo -e " 🌐 伪装域名 (SNI)       : ${CYAN}${OPTIMIZED_SNI}${PLAIN}"
echo -e " 🩺 进程状态             : Hysteria2 ${HY_OK}   Xray ${XR_OK}"
echo -e "----------------------------------------------------------------"
echo -e " [1] Hysteria 2 (Gecko, UDP, >=v2.9.2)"
echo -e "   - 认证密码 : ${CYAN}${HY_PASS}${PLAIN}"
echo -e "   - 混淆类型 : ${CYAN}${OBFS_TYPE}${PLAIN}"
echo -e "   - 混淆密码 : ${CYAN}${HY_OBFS_PASS}${PLAIN}"
echo -e "----------------------------------------------------------------"
echo -e " [2] VLESS-REALITY (Xray, TCP + XTLS-Vision)"
echo -e "   - UUID        : ${CYAN}${VLESS_UUID}${PLAIN}"
echo -e "   - flow        : ${CYAN}xtls-rprx-vision${PLAIN}"
echo -e "   - PublicKey   : ${CYAN}${REALITY_PUB}${PLAIN}"
echo -e "   - ShortId     : ${CYAN}${SHORT_ID}${PLAIN}"
echo -e "   - Fingerprint : ${CYAN}chrome${PLAIN}"
echo -e "----------------------------------------------------------------"
echo -e "${YELLOW}[Hysteria 2 直连链接]:${PLAIN}"
echo -e "${CYAN}hy2://${HY_PASS}@${SERVER_IP}:${PORT}?insecure=1&sni=${OPTIMIZED_SNI}&obfs=gecko&obfs-password=${HY_OBFS_PASS}#Hy2-SharedPort${PLAIN}"
echo -e "\n${YELLOW}[VLESS-REALITY 直连链接]:${PLAIN}"
echo -e "${CYAN}vless://${VLESS_UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${OPTIMIZED_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-REALITY-SharedPort${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e " 配置文件: /etc/hysteria/config.yaml  |  /usr/local/etc/xray/config.json"
echo -e " 日志文件: /var/log/hysteria.log      |  /var/log/xray/error.log"
echo -e " 防火墙提醒: 需同時放行 ${PORT}/TCP 與 ${PORT}/UDP (NAT VPS 通常需額外 UDP 轉發)"
echo -e "${GREEN}================================================================${PLAIN}"
