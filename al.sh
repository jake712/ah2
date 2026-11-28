#!/bin/sh
# =========================================================================
# Hysteria 2 (Gecko) + AnyTLS + VLESS-Reality + TUIC Alpine 部署脚本
# 适用: Alpine Linux 3.20+ (NAT VPS / LXC 容器均可, OpenRC 可用即可)
#
# NAT VPS 适配:
# [A] 无端口占用扫描, 四协议端口保证互不相同
# [B] -p/-t/-v/-u 可选指定端口, 不指定则自动随机分配
# [C] 节点命名: 国家代号 + IP 尾 2 位 (如 SG-47)
# [D] Reality 伪装站复用智能优选 SNI 结果 (TLS1.3 + H2 大站)
#
# 转发要求: hy2=UDP / anytls=TCP / vless-reality=TCP / tuic=UDP
# =========================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

CUSTOM_HY_PORT=""; CUSTOM_ATLS_PORT=""; CUSTOM_VLESS_PORT=""; CUSTOM_TUIC_PORT=""; CUSTOM_IP=""

while getopts "p:t:v:u:i:h" opt; do
  case $opt in
    p) CUSTOM_HY_PORT=$OPTARG ;;
    t) CUSTOM_ATLS_PORT=$OPTARG ;;
    v) CUSTOM_VLESS_PORT=$OPTARG ;;
    u) CUSTOM_TUIC_PORT=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [选项]"
       echo "  -p <端口>  Hysteria2 (UDP) 端口"
       echo "  -t <端口>  AnyTLS (TCP) 端口"
       echo "  -v <端口>  VLESS-Reality (TCP) 端口"
       echo "  -u <端口>  TUIC (UDP) 端口"
       echo "  -i <IP>    手动指定公网 IP"
       exit 0 ;;
  esac
done

[ "$(id -u)" = "0" ] || { echo -e "${RED}错误: 请使用 root 权限运行${PLAIN}"; exit 1; }
echo -e "${GREEN}=== 开始部署 Hy2 + AnyTLS + VLESS-Reality + TUIC (NAT VPS 版) ===${PLAIN}"

# ===== [1/9] 基础环境 =====
echo -e "${YELLOW}[1/9] 检查并配置系统环境...${PLAIN}"
if ! grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  [ -s /etc/resolv.conf ] && grep -q "nameserver" /etc/resolv.conf || \
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
fi
command -v apk >/dev/null 2>&1 || { echo -e "${RED}错误: 仅支持 Alpine Linux${PLAIN}"; exit 1; }
apk update -q
apk add --no-cache curl openssl ca-certificates unzip openrc

# ===== [2/9] 端口分配 =====
echo -e "${YELLOW}[2/9] 正在初始化端口与安全密钥...${PLAIN}"
PORT_POOL_START=40000
PORT_POOL_END=60000

rand_port() {
  R_RP=$(head -c 4 /dev/urandom 2>/dev/null | cksum | awk '{print $1}')
  case "$R_RP" in ''|*[!0-9]*) R_RP=0 ;; esac
  echo $(( (R_RP % (PORT_POOL_END - PORT_POOL_START + 1)) + PORT_POOL_START ))
}
gen_distinct_port() {
  EXCLUDE_GDP=$1; TRY_GDP=0
  while [ $TRY_GDP -lt 100 ]; do
    P_GDP=$(rand_port)
    case ",$EXCLUDE_GDP," in
      *",$P_GDP,"*) TRY_GDP=$((TRY_GDP+1)) ;;
      *) echo "$P_GDP"; return 0 ;;
    esac
  done
  return 1
}
validate_port() {
  case "$1" in ''|*[!0-9]*) echo -e "${RED}错误: 端口必须是纯数字${PLAIN}"; return 1 ;; esac
  return 0
}

USED_PORTS=""
assign_port() {   # $1=自定义端口 $2=标签
  P=$1
  if [ -n "$P" ]; then
    validate_port "$P" || exit 1
  else
    P=$(gen_distinct_port "$USED_PORTS") || { echo -e "${RED}错误: ${2} 端口分配失败, 请手动指定${PLAIN}"; exit 1; }
  fi
  case ",$USED_PORTS," in *",$P,"*) echo -e "${RED}错误: 端口 ${P} 已被其他协议使用${PLAIN}"; exit 1 ;; esac
  USED_PORTS="${USED_PORTS},${P}"
  echo "$P"
}

HY_PORT=$(assign_port "$CUSTOM_HY_PORT"     "Hysteria2");      echo -e "${CYAN}✔ hy2   = ${HY_PORT}/UDP${PLAIN}"
ATLS_PORT=$(assign_port "$CUSTOM_ATLS_PORT" "AnyTLS");         echo -e "${CYAN}✔ atls  = ${ATLS_PORT}/TCP${PLAIN}"
VLESS_PORT=$(assign_port "$CUSTOM_VLESS_PORT" "VLESS-Reality"); echo -e "${CYAN}✔ vless = ${VLESS_PORT}/TCP${PLAIN}"
TUIC_PORT=$(assign_port "$CUSTOM_TUIC_PORT"  "TUIC");          echo -e "${CYAN}✔ tuic  = ${TUIC_PORT}/UDP${PLAIN}"
echo -e "${YELLOW}提醒: 请确认以上端口已在服务商转发规则放行 (hy2/tuic 需 UDP)${PLAIN}"

HY_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
HY_OBFS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
ATLS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
TUIC_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
TUIC_UUID=$(cat /proc/sys/kernel/random/uuid)
REALITY_SHORT_ID=$(head -c 4 /dev/urandom | cksum | awk '{printf "%08x", ($1 % 4294967295)}')

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  ARCH_STR="amd64";  XRAY_STR="64";       TUIC_STR="x86_64" ;;
  aarch64|arm64) ARCH_STR="arm64";  XRAY_STR="arm64-v8a"; TUIC_STR="aarch64" ;;
  *) ARCH_STR="amd64"; XRAY_STR="64"; TUIC_STR="x86_64" ;;
esac

mkdir -p /etc/hysteria /etc/xray /etc/tuic /usr/local/bin /var/log
chmod 700 /etc/hysteria /etc/xray /etc/tuic

# ===== [3/9] 下载核心组件 =====
echo -e "${YELLOW}[3/9] 下载核心组件...${PLAIN}"

# Hysteria2
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH_STR}"
rm -f /tmp/hysteria
for url in "$HY_URL" "https://ghfast.top/$HY_URL"; do
  curl -fsSL --max-time 30 -o /tmp/hysteria "$url" && break
done
[ ! -s /tmp/hysteria ] && { echo -e "${RED}错误: Hysteria 2 下载失败${PLAIN}"; exit 1; }
mv /tmp/hysteria /usr/local/bin/hysteria && chmod 755 /usr/local/bin/hysteria

# AnyTLS (可选)
ATLS_ZIP_URL=$(curl -s --max-time 10 "https://api.github.com/repos/anytls/anytls-go/releases/latest" \
  | grep "browser_download_url.*linux_${ARCH_STR}\.zip" | cut -d '"' -f 4 | head -n 1)
INSTALL_ATLS=0
if [ -n "$ATLS_ZIP_URL" ]; then
  rm -f /tmp/anytls.zip
  for url in "$ATLS_ZIP_URL" "https://ghfast.top/$ATLS_ZIP_URL"; do
    curl -fsSL --max-time 30 -o /tmp/anytls.zip "$url" && break
  done
  if [ -s /tmp/anytls.zip ]; then
    unzip -qo /tmp/anytls.zip -d /tmp/
    ATLS_BIN=$(find /tmp -maxdepth 1 -type f \( -name "anytls-server" -o -name "anytls" \) | head -n 1)
    if [ -n "$ATLS_BIN" ] && [ -s "$ATLS_BIN" ]; then
      INSTALL_ATLS=1; mv "$ATLS_BIN" /usr/local/bin/anytls-server; chmod 755 /usr/local/bin/anytls-server
    fi
  fi
fi
[ "$INSTALL_ATLS" = "1" ] || echo -e "${YELLOW}提示: AnyTLS 下载失败, 将跳过${PLAIN}"

# Xray (VLESS-Reality, 可选)
INSTALL_VLESS=0
XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_STR}.zip"
rm -f /tmp/xrayzip; rm -rf /tmp/xray-extract; mkdir -p /tmp/xray-extract
for url in "$XRAY_URL" "https://ghfast.top/$XRAY_URL"; do
  curl -fsSL --max-time 60 -o /tmp/xrayzip "$url" && break
done
REALITY_PRIVATE=""; REALITY_PUBLIC=""
if [ -s /tmp/xrayzip ]; then
  unzip -qo /tmp/xrayzip -d /tmp/xray-extract/ 2>/dev/null
  if [ -x /tmp/xray-extract/xray ]; then
    INSTALL_VLESS=1
    mv /tmp/xray-extract/xray /usr/local/bin/xray
    chmod 755 /usr/local/bin/xray
    X25519_OUT=$(/usr/local/bin/xray x25519 2>/dev/null)
    REALITY_PRIVATE=$(printf '%s\n' "$X25519_OUT" | grep -i "Private key" | awk '{print $NF}')
    REALITY_PUBLIC=$(printf '%s\n' "$X25519_OUT" | grep -i "Public key" | awk '{print $NF}')
  fi
fi
[ "$INSTALL_VLESS" = "1" ] || echo -e "${YELLOW}提示: Xray 下载失败, 将跳过 VLESS-Reality${PLAIN}"

# TUIC (可选)
INSTALL_TUIC=0
TUIC_API="https://api.github.com/repos/EAimON/tuic/releases/latest"
TUIC_URL=$(curl -s --max-time 10 "$TUIC_API" \
  | grep "browser_download_url.*tuic-server.*linux.*${TUIC_STR}" | cut -d '"' -f 4 | head -n 1)
if [ -n "$TUIC_URL" ]; then
  rm -f /tmp/tuic
  for url in "$TUIC_URL" "https://ghfast.top/$TUIC_URL"; do
    curl -fsSL --max-time 30 -o /tmp/tuic "$url" && break
  done
  if [ -s /tmp/tuic ]; then
    INSTALL_TUIC=1; mv /tmp/tuic /usr/local/bin/tuic-server; chmod 755 /usr/local/bin/tuic-server
  fi
fi
[ "$INSTALL_TUIC" = "1" ] || echo -e "${YELLOW}提示: TUIC 下载失败, 将跳过 TUIC${PLAIN}"

# ===== [4/9] 内核 UDP 缓冲区调优 =====
echo -e "${YELLOW}[4/9] 调整内核 UDP 缓冲区参数...${PLAIN}"
cat > /etc/sysctl.d/99-proxy.conf <<'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.udp_mem=1048576 2097152 4194304
EOF
sysctl -p /etc/sysctl.d/99-proxy.conf 2>/dev/null || \
  echo -e "${YELLOW}提示: 内核参数应用失败 (LXC 常见), 已写入配置文件${PLAIN}"

# ===== [5/9] 优选 SNI (hy2 与 Reality 复用) 并生成证书 =====
echo -e "${YELLOW}[5/9] 智能优选 SNI 并生成证书...${PLAIN}"
SNI_CANDIDATES="www.amd.com www.apple.com pypi.org www.samsung.com www.sony.com www.oracle.com www.deb.debian.org"

# 共用优选函数: 测连接延迟, 返回最优域名
pick_best_sni() {
  BEST_DOMAIN="www.bing.com"
  BEST_LATENCY=9999
  for domain in $SNI_CANDIDATES; do
    latency=$(curl -o /dev/null -s -w '%{time_connect}\n' --connect-timeout 2 -m 3 "https://$domain" 2>/dev/null || echo "999")
    is_better=$(awk -v l="$latency" -v min="$BEST_LATENCY" 'BEGIN {if (l > 0 && l < min) print 1; else print 0}')
    [ "$is_better" = "1" ] && { BEST_LATENCY=$latency; BEST_DOMAIN=$domain; }
  done
  echo "$BEST_DOMAIN"
}

# hy2 伪装 SNI 与 Reality 伪装站共用同一优选结果
OPTIMIZED_SNI=$(pick_best_sni)
echo -e "${CYAN}✔ Hy2 伪装 SNI : ${OPTIMIZED_SNI}${PLAIN}"

REALITY_SNI="$OPTIMIZED_SNI"
REALITY_DEST="${REALITY_SNI}:443"
echo -e "${CYAN}✔ Reality 伪装站: ${REALITY_SNI} (dest=${REALITY_DEST})${PLAIN}"

# 证书生成 (hy2 / TUIC 自签, Reality 不需要证书)
rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null
openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt \
  -subj "/CN=${OPTIMIZED_SNI}" -days 3650 2>/dev/null
chmod 600 /etc/hysteria/key.key
PIN_SHA256=$(openssl x509 -in /etc/hysteria/cert.crt -noout -fingerprint -sha256 \
  | awk -F= '{gsub(":","",$2); print tolower($2)}')
cp /etc/hysteria/cert.crt /etc/tuic/cert.crt
cp /etc/hysteria/key.key  /etc/tuic/key.key

# ===== [6/9] 生成各协议配置 =====
echo -e "${YELLOW}[6/9] 生成各协议配置...${PLAIN}"

cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}
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

# VLESS-Reality 配置 (JSON)
if [ "$INSTALL_VLESS" = "1" ]; then
cat > /etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${VLESS_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${VLESS_UUID}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${REALITY_DEST}",
        "xver": 0,
        "serverNames": ["${REALITY_SNI}"],
        "privateKey": "${REALITY_PRIVATE}",
        "shortIds": ["${REALITY_SHORT_ID}"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
fi

# TUIC 配置 (TOML)
if [ "$INSTALL_TUIC" = "1" ]; then
cat > /etc/tuic/config.toml <<EOF
server = "0.0.0.0:${TUIC_PORT}"
users = ["${TUIC_UUID}:${TUIC_PASS}"]
udp_relay_ipv6 = true
congestion_control = "bbr"
alpn = ["h3"]
certificate = "/etc/tuic/cert.crt"
private_key = "/etc/tuic/key.key"
EOF
fi

# ===== [7/9] 写入 info.env + 服务单元 + hys 管理命令 =====
echo -e "${YELLOW}[7/9] 写入配置数据库与服务单元...${PLAIN}"
SERVER_IP="$CUSTOM_IP"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 4 api.ipify.org || curl -4s --max-time 4 ifconfig.me || echo "YOUR_SERVER_IP")
fi

# 节点名称: 国家代号 + IP 尾 2 位 (如 SG-47)
NODE_CC=$(curl -4s --max-time 5 https://ipinfo.io/country | tr -d '[:space:]')
case "$NODE_CC" in ''|*[!a-zA-Z]*) NODE_CC="XX" ;; esac
NODE_TAIL=$(printf '%s' "$SERVER_IP" | awk '{print substr($0, length($0)-1)}')
NODE_TAG="${NODE_CC}-${NODE_TAIL}"
echo -e "${CYAN}✔ 节点名称: ${NODE_TAG}${PLAIN}"

cat > /etc/hysteria/info.env <<EOF
HY_PORT=${HY_PORT}
ATLS_PORT=${ATLS_PORT}
VLESS_PORT=${VLESS_PORT}
TUIC_PORT=${TUIC_PORT}
HY_PASS=${HY_PASS}
HY_OBFS_PASS=${HY_OBFS_PASS}
ATLS_PASS=${ATLS_PASS}
VLESS_UUID=${VLESS_UUID}
TUIC_UUID=${TUIC_UUID}
TUIC_PASS=${TUIC_PASS}
REALITY_PUBLIC=${REALITY_PUBLIC}
REALITY_SNI=${REALITY_SNI}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
HY_SNI=${OPTIMIZED_SNI}
HY_PIN=${PIN_SHA256}
SERVER_IP=${SERVER_IP}
NODE_TAG=${NODE_TAG}
EOF
chmod 600 /etc/hysteria/info.env

# --- OpenRC 服务单元 ---
cat > /etc/init.d/hysteria2 <<'EOF'
#!/sbin/openrc-run
name="hysteria2"
description="Hysteria2 QUIC proxy server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria2.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
depend() { need net; use dns; }
EOF
chmod +x /etc/init.d/hysteria2

if [ "$INSTALL_ATLS" = "1" ]; then
cat > /etc/init.d/anytls <<'EOF'
#!/sbin/openrc-run
. /etc/hysteria/info.env
name="anytls"
description="AnyTLS TLS proxy server"
command="/usr/local/bin/anytls-server"
command_args="-l :${ATLS_PORT} -p ${ATLS_PASS}"
command_background="yes"
pidfile="/run/anytls.pid"
output_log="/var/log/anytls.log"
error_log="/var/log/anytls.log"
depend() { need net; use dns; }
EOF
chmod +x /etc/init.d/anytls
fi

if [ "$INSTALL_VLESS" = "1" ]; then
cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
name="xray"
description="Xray VLESS-Reality server"
command="/usr/local/bin/xray"
command_args="run -c /etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.log"
depend() { need net; use dns; }
EOF
chmod +x /etc/init.d/xray
fi

if [ "$INSTALL_TUIC" = "1" ]; then
cat > /etc/init.d/tuic <<'EOF'
#!/sbin/openrc-run
name="tuic"
description="TUIC v5 QUIC proxy server"
command="/usr/local/bin/tuic-server"
command_args="-c /etc/tuic/config.toml"
command_background="yes"
pidfile="/run/tuic.pid"
output_log="/var/log/tuic.log"
error_log="/var/log/tuic.log"
depend() { need net; use dns; }
EOF
chmod +x /etc/init.d/tuic
fi

# --- hys 管理命令 ---
cat > /usr/local/bin/hys <<'HYSEOF'
#!/bin/sh
# hys - 四协议 (Hy2/AnyTLS/VLESS-Reality/TUIC) 管理命令
INFO_ENV=/etc/hysteria/info.env
HY_CONFIG=/etc/hysteria/config.yaml
XRAY_CONFIG=/etc/xray/config.json
TUIC_CONFIG=/etc/tuic/config.toml
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; PLAIN='\033[0m'

[ "$(id -u)" = "0" ] || { echo "错误: 请使用 root 权限运行 hys"; exit 1; }
[ -f "$INFO_ENV" ] || { echo "错误: 未找到 $INFO_ENV, 请先运行部署脚本"; exit 1; }
. "$INFO_ENV"

print_help() {
cat <<'HEOF'
用法: hys <子命令> [参数]
  set hy2|anytls|vless|tuic <port>   修改指定协议端口
  set reality <域名>                 更换 Reality 伪装站 (需 TLS1.3 大站)
  newpass                            重新生成 Hy2 认证密码
  newobfs                            重新生成 Hy2 混淆密码
  newuuid                            重新生成 VLESS 与 TUIC 的 UUID
  newtuicpass                        重新生成 TUIC 密码
  info                               显示当前配置与分享链接
  start|stop|restart|status          服务管理 (全部协议)
  help                               显示本帮助

注: 端口仅要求纯数字, 四协议端口不得相同;
    NAT VPS 请使用服务商转发范围内的端口 (hy2/tuic 需 UDP 转发)
HEOF
}

validate_port() {
  case "$1" in ''|*[!0-9]*) echo -e "${RED}错误: 端口必须是纯数字${PLAIN}"; return 1 ;; esac
  return 0
}

print_links() {
  echo ""
  echo -e "${GREEN}=== 当前配置 ===${PLAIN}"
  echo -e "  节点名称     : ${CYAN}${NODE_TAG}${PLAIN}"
  echo -e "  服务器地址   : ${CYAN}${SERVER_IP}${PLAIN}"
  echo -e "  Hy2 端口     : ${CYAN}${HY_PORT}${PLAIN} (UDP)"
  echo -e "  AnyTLS 端口  : ${CYAN}${ATLS_PORT}${PLAIN} (TCP)"
  echo -e "  VLESS 端口   : ${CYAN}${VLESS_PORT}${PLAIN} (TCP)"
  echo -e "  TUIC 端口    : ${CYAN}${TUIC_PORT}${PLAIN} (UDP)"
  echo -e "  Hy2 伪装 SNI : ${CYAN}${HY_SNI}${PLAIN}"
  echo -e "  Reality 站点 : ${CYAN}${REALITY_SNI}${PLAIN}"
  echo ""
  echo -e "${YELLOW}[Hysteria2]${PLAIN}"
  echo -e "${CYAN}hy2://${HY_PASS}@${SERVER_IP}:${HY_PORT}?pinSHA256=${HY_PIN}&sni=${HY_SNI}&obfs=gecko&obfs-password=${HY_OBFS_PASS}#Hy2-${NODE_TAG}${PLAIN}"
  echo ""
  echo -e "${YELLOW}[AnyTLS]${PLAIN}"
  echo -e "${CYAN}anytls://${ATLS_PASS}@${SERVER_IP}:${ATLS_PORT}?sni=${HY_SNI}&insecure=1#AnyTLS-${NODE_TAG}${PLAIN}"
  echo ""
  echo -e "${YELLOW}[VLESS-Reality]${PLAIN}"
  echo -e "${CYAN}vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?security=reality&encryption=none&pbk=${REALITY_PUBLIC}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${REALITY_SNI}&sid=${REALITY_SHORT_ID}#Vless-${NODE_TAG}${PLAIN}"
  echo ""
  echo -e "${YELLOW}[TUIC]${PLAIN}"
  echo -e "${CYAN}tuic://${TUIC_UUID}:${TUIC_PASS}@${SERVER_IP}:${TUIC_PORT}?sni=${HY_SNI}&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#Tuic-${NODE_TAG}${PLAIN}"
  echo ""
}

restart_one() {
  case "$1" in
    hy2)    rc-service hysteria2 restart >/dev/null 2>&1 ;;
    anytls) [ -f /etc/init.d/anytls ] && rc-service anytls restart >/dev/null 2>&1 ;;
    vless)  [ -f /etc/init.d/xray ] && rc-service xray restart >/dev/null 2>&1 ;;
    tuic)   [ -f /etc/init.d/tuic ] && rc-service tuic restart >/dev/null 2>&1 ;;
  esac
}

do_set_port() {
  TARGET=$1; NEW_PORT=$2
  case "$TARGET" in
    hy2)    VAR=HY_PORT;    SVC_FILE=/etc/init.d/hysteria2 ;;
    anytls) VAR=ATLS_PORT;  SVC_FILE=/etc/init.d/anytls ;;
    vless)  VAR=VLESS_PORT; SVC_FILE=/etc/init.d/xray ;;
    tuic)   VAR=TUIC_PORT;  SVC_FILE=/etc/init.d/tuic ;;
  esac
  [ -f "$SVC_FILE" ] || { echo -e "${RED}错误: ${TARGET} 未安装${PLAIN}"; return 1; }
  CUR_PORT=$(eval echo \${$VAR})
  [ "$NEW_PORT" = "$CUR_PORT" ] && { echo "${TARGET} 端口已是 ${NEW_PORT}"; return 0; }
  for v in HY_PORT ATLS_PORT VLESS_PORT TUIC_PORT; do
    [ "$v" = "$VAR" ] && continue
    P=$(eval echo \${$v})
    [ "$P" = "$NEW_PORT" ] && { echo -e "${RED}错误: 端口 ${NEW_PORT} 已被其他协议使用${PLAIN}"; return 1; }
  done
  case "$TARGET" in
    hy2)    sed -i "s|^listen:.*|listen: :${NEW_PORT}|" "$HY_CONFIG" ;;
    anytls) sed -i "s|command_args=\"-l :[0-9]* -p ${ATLS_PASS}\"|command_args=\"-l :${NEW_PORT} -p ${ATLS_PASS}\"|" "$SVC_FILE" ;;
    vless)  sed -i "s|\"port\": ${CUR_PORT}|\"port\": ${NEW_PORT}|" "$XRAY_CONFIG" ;;
    tuic)   sed -i "s|server = \"0.0.0.0:${CUR_PORT}\"|server = \"0.0.0.0:${NEW_PORT}\"|" "$TUIC_CONFIG" ;;
  esac
  sed -i "s|^${VAR}=.*|${VAR}=${NEW_PORT}|" "$INFO_ENV"
  restart_one "$TARGET"
  . "$INFO_ENV"
  echo -e "${GREEN}✔ ${TARGET} 端口已更新为 ${NEW_PORT}${PLAIN}"
  print_links
}

do_set_reality() {
  NEW_DOMAIN=$1
  [ -f /etc/init.d/xray ] || { echo -e "${RED}错误: VLESS-Reality 未安装${PLAIN}"; return 1; }
  case "$NEW_DOMAIN" in
    *"://"*|*" "*) echo -e "${RED}错误: 请仅输入域名, 如 www.apple.com${PLAIN}"; return 1 ;;
  esac
  CUR_SNI="$REALITY_SNI"
  sed -i "s|\"dest\": \"${CUR_SNI}:443\"|\"dest\": \"${NEW_DOMAIN}:443\"|" "$XRAY_CONFIG"
  sed -i "s|\"serverNames\": \[\"${CUR_SNI}\"\]|\"serverNames\": [\"${NEW_DOMAIN}\"]|" "$XRAY_CONFIG"
  sed -i "s|^REALITY_SNI=.*|REALITY_SNI=${NEW_DOMAIN}|" "$INFO_ENV"
  restart_one vless
  . "$INFO_ENV"
  echo -e "${GREEN}✔ Reality 伪装站已更换为 ${NEW_DOMAIN}${PLAIN}"
  print_links
}

cmd_set() {
  case "$1" in
    hy2|anytls|vless|tuic)
      [ $# -ne 2 ] && { echo "用法: hys set <hy2|anytls|vless|tuic> <port>"; return 1; }
      validate_port "$2" && do_set_port "$1" "$2" ;;
    reality)
      [ $# -ne 2 ] && { echo "用法: hys set reality <域名>"; return 1; }
      do_set_reality "$2" ;;
    *) echo -e "${RED}未知目标 '$1', 可用值: hy2 / anytls / vless / tuic / reality${PLAIN}"; return 1 ;;
  esac
}

cmd_newpass() {
  NEW_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
  sed -i "s|^HY_PASS=.*|HY_PASS=${NEW_PASS}|" "$INFO_ENV"
  sed -i "s|^  password: .*|  password: ${NEW_PASS}|" "$HY_CONFIG"
  restart_one hy2; . "$INFO_ENV"
  echo -e "${GREEN}✔ Hy2 认证密码已更新${PLAIN}"; print_links
}

cmd_newobfs() {
  NEW_OBFS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
  sed -i "s|^HY_OBFS_PASS=.*|HY_OBFS_PASS=${NEW_OBFS}|" "$INFO_ENV"
  sed -i "s|^    password: .*|    password: ${NEW_OBFS}|" "$HY_CONFIG"
  restart_one hy2; . "$INFO_ENV"
  echo -e "${GREEN}✔ Hy2 混淆密码已更新${PLAIN}"; print_links
}

cmd_newuuid() {
  NEW_VUUID=$(cat /proc/sys/kernel/random/uuid)
  NEW_TUUID=$(cat /proc/sys/kernel/random/uuid)
  sed -i "s|^VLESS_UUID=.*|VLESS_UUID=${NEW_VUUID}|" "$INFO_ENV"
  sed -i "s|^TUIC_UUID=.*|TUIC_UUID=${NEW_TUUID}|" "$INFO_ENV"
  [ -f "$XRAY_CONFIG" ] && sed -i "s|\"id\": \"${VLESS_UUID}\"|\"id\": \"${NEW_VUUID}\"|" "$XRAY_CONFIG"
  [ -f "$TUIC_CONFIG" ] && sed -i "s|\"${TUIC_UUID}:${TUIC_PASS}\"|\"${NEW_TUUID}:${TUIC_PASS}\"|" "$TUIC_CONFIG"
  restart_one vless; restart_one tuic; . "$INFO_ENV"
  echo -e "${GREEN}✔ VLESS / TUIC UUID 已更新${PLAIN}"; print_links
}

cmd_newtuicpass() {
  NEW_TP=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
  sed -i "s|^TUIC_PASS=.*|TUIC_PASS=${NEW_TP}|" "$INFO_ENV"
  [ -f "$TUIC_CONFIG" ] && sed -i "s|\"${TUIC_UUID}:${TUIC_PASS}\"|\"${TUIC_UUID}:${NEW_TP}\"|" "$TUIC_CONFIG"
  restart_one tuic; . "$INFO_ENV"
  echo -e "${GREEN}✔ TUIC 密码已更新${PLAIN}"; print_links
}

cmd_start() {
  rc-service hysteria2 start
  [ -f /etc/init.d/anytls ] && rc-service anytls start
  [ -f /etc/init.d/xray ]   && rc-service xray start
  [ -f /etc/init.d/tuic ]   && rc-service tuic start
}
cmd_stop() {
  rc-service hysteria2 stop 2>/dev/null
  rc-service anytls stop 2>/dev/null
  rc-service xray stop 2>/dev/null
  rc-service tuic stop 2>/dev/null
}
cmd_restart() { cmd_stop; sleep 1; cmd_start; }
cmd_status() {
  rc-service hysteria2 status
  [ -f /etc/init.d/anytls ] && rc-service anytls status
  [ -f /etc/init.d/xray ]   && rc-service xray status
  [ -f /etc/init.d/tuic ]   && rc-service tuic status
}

case "$1" in
  set) shift; cmd_set "$@" ;;
  newpass) cmd_newpass ;;
  newobfs) cmd_newobfs ;;
  newuuid) cmd_newuuid ;;
  newtuicpass) cmd_newtuicpass ;;
  info) print_links ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_restart ;;
  status) cmd_status ;;
  help|-h|--help|"") print_help ;;
  *) echo "未知子命令: $1"; print_help; exit 1 ;;
esac
HYSEOF
chmod 755 /usr/local/bin/hys

# ===== [8/9] 启动服务 =====
echo -e "${YELLOW}[8/9] 启动服务...${PLAIN}"
rc-service hysteria2 stop 2>/dev/null || true
rc-service anytls stop 2>/dev/null || true
rc-service xray stop 2>/dev/null || true
rc-service tuic stop 2>/dev/null || true
sleep 1

rc-update add hysteria2 default
rc-service hysteria2 start
[ "$INSTALL_ATLS" = "1" ]  && { rc-update add anytls default; rc-service anytls start; }
[ "$INSTALL_VLESS" = "1" ] && { rc-update add xray default;   rc-service xray start; }
[ "$INSTALL_TUIC" = "1" ]  && { rc-update add tuic default;   rc-service tuic start; }
sleep 2
rc-service hysteria2 status || true
[ "$INSTALL_ATLS" = "1" ]  && rc-service anytls status || true
[ "$INSTALL_VLESS" = "1" ] && rc-service xray status || true
[ "$INSTALL_TUIC" = "1" ]  && rc-service tuic status || true

# ===== [9/9] 输出结果 =====
echo -e "\n${GREEN}================================================================${PLAIN}"
echo -e "${GREEN}🎉 部署完成！(NAT VPS / 四协议)${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e " 📍 节点名称       : ${CYAN}${NODE_TAG}${PLAIN}"
echo -e " 📍 服务器地址     : ${CYAN}${SERVER_IP}${PLAIN}"
echo -e " 🔢 Hysteria2      : ${CYAN}${HY_PORT}${PLAIN} (UDP)"
echo -e " 🔢 AnyTLS         : ${CYAN}${ATLS_PORT}${PLAIN} (TCP)  $([ "$INSTALL_ATLS" = "1" ] || echo '(未安装)')"
echo -e " 🔢 VLESS-Reality  : ${CYAN}${VLESS_PORT}${PLAIN} (TCP)  $([ "$INSTALL_VLESS" = "1" ] || echo '(未安装)')"
echo -e " 🔢 TUIC           : ${CYAN}${TUIC_PORT}${PLAIN} (UDP)  $([ "$INSTALL_TUIC" = "1" ] || echo '(未安装)')"
echo -e " 🌐 Hy2 伪装 SNI   : ${CYAN}${OPTIMIZED_SNI}${PLAIN}"
echo -e " 🌐 Reality 伪装站 : ${CYAN}${REALITY_SNI}${PLAIN} (复用优选 SNI)"
echo -e "----------------------------------------------------------------"
echo -e "${YELLOW}[Hysteria 2 直连链接]${PLAIN}"
echo -e "${CYAN}hy2://${HY_PASS}@${SERVER_IP}:${HY_PORT}?pinSHA256=${PIN_SHA256}&sni=${OPTIMIZED_SNI}&obfs=gecko&obfs-password=${HY_OBFS_PASS}#Hy2-${NODE_TAG}${PLAIN}"
if [ "$INSTALL_ATLS" = "1" ]; then
  echo -e "\n${YELLOW}[AnyTLS 直连链接]${PLAIN}"
  echo -e "${CYAN}anytls://${ATLS_PASS}@${SERVER_IP}:${ATLS_PORT}?sni=${OPTIMIZED_SNI}&insecure=1#AnyTLS-${NODE_TAG}${PLAIN}"
fi
if [ "$INSTALL_VLESS" = "1" ]; then
  echo -e "\n${YELLOW}[VLESS-Reality 直连链接]${PLAIN}"
  echo -e "${CYAN}vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?security=reality&encryption=none&pbk=${REALITY_PUBLIC}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${REALITY_SNI}&sid=${REALITY_SHORT_ID}#Vless-${NODE_TAG}${PLAIN}"
fi
if [ "$INSTALL_TUIC" = "1" ]; then
  echo -e "\n${YELLOW}[TUIC 直连链接]${PLAIN}"
  echo -e "${CYAN}tuic://${TUIC_UUID}:${TUIC_PASS}@${SERVER_IP}:${TUIC_PORT}?sni=${OPTIMIZED_SNI}&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#Tuic-${NODE_TAG}${PLAIN}"
fi
echo -e "${GREEN}================================================================${PLAIN}"
echo -e "${YELLOW}[NAT VPS 检查清单]${PLAIN}"
echo -e "  1. 放行转发: ${HY_PORT}/UDP  ${ATLS_PORT}/TCP  ${VLESS_PORT}/TCP  ${TUIC_PORT}/UDP"
echo -e "  2. 不在转发范围时用 hys set 修改"
echo -e "  3. hy2 / tuic 连不上时优先确认服务商是否转发 UDP"
echo -e "${YELLOW}[管理命令]${PLAIN}"
echo -e "  hys set <hy2|anytls|vless|tuic> <端口>   # 修改端口"
echo -e "  hys set reality <域名>                    # 更换 Reality 伪装站"
echo -e "  hys newpass / newobfs / newuuid / newtuicpass"
echo -e "  hys info / restart / status"
echo -e "${GREEN}================================================================${PLAIN}"
