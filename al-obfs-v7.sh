#!/bin/sh
# =========================================================================
# Hysteria 2 (Gecko) + AnyTLS Alpine 部署脚本（分离端口版）
# 适用: Alpine Linux 3.20/3.21/3.22+ 原生系统 (容器内 OpenRC 不可用)
#
# 功能:
#   [A] 初始部署时 hy2 / anytls 分别随机分配两个不同端口 (均在 40000-60000,
#       分别检查 UDP / TCP 占用, 两端口保证不相同)
#   [B] 配置持久化到 /etc/hysteria/info.env (HY_PORT 与 ATLS_PORT 独立)
#   [C] AnyTLS OpenRC 服务单元动态读取 info.env
#   [D] hys 管理命令 (同端口模式已移除):
#       hys set hy2 <port>      只修改 Hysteria2 (UDP) 端口
#       hys set anytls <port>   只修改 AnyTLS (TCP) 端口
#       hys newpass / newobfs / info / start / stop / restart / status
#   [E] 端口范围强制 40000-60000
# =========================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

CUSTOM_HY_PORT=""
CUSTOM_ATLS_PORT=""
CUSTOM_IP=""

while getopts "p:t:i:h" opt; do
  case $opt in
    p) CUSTOM_HY_PORT=$OPTARG ;;
    t) CUSTOM_ATLS_PORT=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h)
      echo "用法: $0 [选项]"
      echo "  -p <端口>   自定义 Hysteria2 (UDP) 端口 (默认在 40000-60000 随机)"
      echo "  -t <端口>   自定义 AnyTLS (TCP) 端口   (默认在 40000-60000 随机)"
      echo "  -i <公网IP> 手动指定服务器公网 IP"
      echo "注: 两个端口必须不同 (本版已移除同端口模式)"
      exit 0
      ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
  exit 1
fi

echo -e "${GREEN}=== 开始部署 Hysteria 2 (Gecko) + AnyTLS (分离端口版) ===${PLAIN}"

# ===== [1/7] 基础环境与依赖 =====
echo -e "${YELLOW}[1/7] 检查并配置系统环境...${PLAIN}"
if ! grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
  fi
fi

if ! command -v apk >/dev/null 2>&1; then
  echo -e "${RED}错误: 未检测到 apk 包管理器，本脚本仅支持 Alpine Linux${PLAIN}"
  exit 1
fi

apk update -q
apk add --no-cache curl openssl ca-certificates gawk iproute2 unzip openrc

# ===== [2/7] 分离端口与密钥初始化 =====
echo -e "${YELLOW}[2/7] 正在初始化分离端口与安全密钥...${PLAIN}"

rand_port() {
  awk 'BEGIN{srand(); print int(rand()*(60000-40000+1))+40000}'
}

# 端口占用检查: $1=udp|tcp $2=端口; 返回 0=被占用 1=空闲
# 注意: ss -Huln / -Htln 的本地地址均在第 4 列
port_in_use() {
  case "$1" in
    udp) ss -Huln 2>/dev/null | awk '{print $4}' | grep -q ":$2\$" ;;
    tcp) ss -Htln 2>/dev/null | awk '{print $4}' | grep -q ":$2\$" ;;
  esac
}

# 在 40000-60000 内随机挑选一个空闲端口, 排除 $2 (可为空); 失败返回 1
gen_free_port() {
  PROTO_GFP=$1
  EXCLUDE_GFP=$2
  TRY_GFP=0
  while [ $TRY_GFP -lt 100 ]; do
    P_GFP=$(rand_port)
    if [ -n "$EXCLUDE_GFP" ] && [ "$P_GFP" = "$EXCLUDE_GFP" ]; then
      TRY_GFP=$((TRY_GFP+1))
      continue
    fi
    if ! port_in_use "$PROTO_GFP" "$P_GFP"; then
      echo "$P_GFP"
      return 0
    fi
    TRY_GFP=$((TRY_GFP+1))
  done
  return 1
}

validate_port_range() {
  case "$1" in
    ''|*[!0-9]*)
      echo -e "${RED}错误: 端口必须是纯数字${PLAIN}"
      return 1
      ;;
  esac
  if [ "$1" -lt 40000 ] || [ "$1" -gt 60000 ]; then
    echo -e "${RED}错误: 端口必须在 40000-60000 范围内${PLAIN}"
    return 1
  fi
  return 0
}

# --- Hysteria2 (UDP) 端口 ---
if [ -n "$CUSTOM_HY_PORT" ]; then
  validate_port_range "$CUSTOM_HY_PORT" || exit 1
  if port_in_use udp "$CUSTOM_HY_PORT"; then
    echo -e "${RED}错误: UDP 端口 ${CUSTOM_HY_PORT} 已被其他进程占用${PLAIN}"
    exit 1
  fi
  HY_PORT=$CUSTOM_HY_PORT
  echo -e "${CYAN}✔ Hysteria2 使用指定端口: ${HY_PORT} (UDP)${PLAIN}"
else
  HY_PORT=$(gen_free_port udp "") || { echo -e "${RED}错误: 40000-60000 内找不到空闲 UDP 端口${PLAIN}"; exit 1; }
  echo -e "${CYAN}✔ Hysteria2 已自动分配端口: ${HY_PORT} (UDP)${PLAIN}"
fi

# --- AnyTLS (TCP) 端口 (必须与 HY_PORT 不同) ---
if [ -n "$CUSTOM_ATLS_PORT" ]; then
  validate_port_range "$CUSTOM_ATLS_PORT" || exit 1
  if [ "$CUSTOM_ATLS_PORT" = "$HY_PORT" ]; then
    echo -e "${RED}错误: AnyTLS 端口不能与 Hysteria2 端口相同 (本版已移除同端口模式)${PLAIN}"
    exit 1
  fi
  if port_in_use tcp "$CUSTOM_ATLS_PORT"; then
    echo -e "${RED}错误: TCP 端口 ${CUSTOM_ATLS_PORT} 已被其他进程占用${PLAIN}"
    exit 1
  fi
  ATLS_PORT=$CUSTOM_ATLS_PORT
  echo -e "${CYAN}✔ AnyTLS 使用指定端口: ${ATLS_PORT} (TCP)${PLAIN}"
else
  ATLS_PORT=$(gen_free_port tcp "$HY_PORT") || { echo -e "${RED}错误: 40000-60000 内找不到与 hy2 不同的空闲 TCP 端口${PLAIN}"; exit 1; }
  echo -e "${CYAN}✔ AnyTLS 已自动分配端口: ${ATLS_PORT} (TCP)${PLAIN}"
fi

echo -e "${GREEN}✔ 端口分离确认: hy2=${HY_PORT}/UDP, anytls=${ATLS_PORT}/TCP${PLAIN}"

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

# ===== [3/7] 下载核心组件 =====
echo -e "${YELLOW}[3/7] 下载核心组件...${PLAIN}"

HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH_STR}"
rm -f /tmp/hysteria
for url in "$HY_URL" "https://ghfast.top/$HY_URL"; do
  curl -fsSL --max-time 30 -o /tmp/hysteria "$url" && break
done
[ ! -s /tmp/hysteria ] && { echo -e "${RED}错误: Hysteria 2 下载失败${PLAIN}"; exit 1; }
mv /tmp/hysteria /usr/local/bin/hysteria
chmod 755 /usr/local/bin/hysteria

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
      mv "$ATLS_BIN" /usr/local/bin/anytls-server
      chmod 755 /usr/local/bin/anytls-server
    fi
  fi
fi

if [ "$INSTALL_ATLS" != "1" ]; then
  echo -e "${YELLOW}提示: AnyTLS 核心未能成功下载，将仅部署 Hysteria 2${PLAIN}"
fi

# ===== [4/7] 内核 UDP 缓冲区调优 =====
echo -e "${YELLOW}[4/7] 调整内核 UDP 缓冲区参数...${PLAIN}"
cat > /etc/sysctl.d/99-hysteria.conf <<'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.udp_mem=1048576 2097152 4194304
EOF
sysctl -p /etc/sysctl.d/99-hysteria.conf 2>/dev/null || \
  echo -e "${YELLOW}提示: 内核参数应用失败 (容器内受限), 已写入 /etc/sysctl.d/99-hysteria.conf${PLAIN}"

# ===== [5/7] 优选 SNI 并生成证书与配置 =====
echo -e "${YELLOW}[5/7] 智能优选 SNI 并生成证书与配置...${PLAIN}"
SNI_CANDIDATES="www.amd.com www.apple.com pypi.org www.samsung.com www.sony.com www.oracle.com www.deb.debian.org"
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
openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt \
  -subj "/CN=${OPTIMIZED_SNI}" -days 3650 2>/dev/null
chmod 600 /etc/hysteria/key.key

PIN_SHA256=$(openssl x509 -in /etc/hysteria/cert.crt -noout -fingerprint -sha256 \
  | awk -F= '{gsub(":","",$2); print tolower($2)}')

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

# ===== [6/7] 写入 info.env + OpenRC 服务单元 + hys 管理命令 =====
echo -e "${YELLOW}[6/7] 写入配置数据库与服务单元...${PLAIN}"

SERVER_IP="$CUSTOM_IP"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 4 api.ipify.org || curl -4s --max-time 4 ifconfig.me || echo "YOUR_SERVER_IP")
fi

cat > /etc/hysteria/info.env <<EOF
HY_PORT=${HY_PORT}
ATLS_PORT=${ATLS_PORT}
HY_PASS=${HY_PASS}
HY_OBFS_PASS=${HY_OBFS_PASS}
ATLS_PASS=${ATLS_PASS}
HY_SNI=${OPTIMIZED_SNI}
HY_PIN=${PIN_SHA256}
SERVER_IP=${SERVER_IP}
EOF
chmod 600 /etc/hysteria/info.env

# Hysteria2 OpenRC 服务单元
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

depend() {
  need net
  use dns
}
EOF
chmod +x /etc/init.d/hysteria2

# AnyTLS OpenRC 服务单元 (动态 source info.env, 使用独立的 ATLS_PORT)
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

depend() {
  need net
  use dns
}
EOF
  chmod +x /etc/init.d/anytls
fi

# 安装 hys 管理命令 (同端口模式已移除)
cat > /usr/local/bin/hys <<'HYSEOF'
#!/bin/sh
# =========================================================================
# hys - Hysteria2 + AnyTLS 一站式管理命令 (分离端口版)
#   hys set hy2 <port>      只修改 Hysteria2 (UDP) 端口
#   hys set anytls <port>   只修改 AnyTLS (TCP) 端口
#   hys newpass             重新生成 Hysteria2 认证密码
#   hys newobfs             重新生成 Hysteria2 混淆密码
#   hys info                显示当前配置与分享链接
#   hys start|stop|restart|status
#   hys help
#
# 端口范围强制 40000-60000, 且两协议端口不得相同
# =========================================================================

INFO_ENV=/etc/hysteria/info.env
HY_CONFIG=/etc/hysteria/config.yaml

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; PLAIN='\033[0m'

if [ "$(id -u)" != "0" ]; then
  echo "错误: 请使用 root 权限运行 hys"
  exit 1
fi

if [ ! -f "$INFO_ENV" ]; then
  echo "错误: 未找到 $INFO_ENV，请先运行部署脚本"
  exit 1
fi

. "$INFO_ENV"

print_help() {
  cat <<'HEOF'
用法: hys <子命令> [参数]

  set hy2 <port>      只修改 Hysteria2 (UDP) 端口 (40000-60000)
  set anytls <port>   只修改 AnyTLS (TCP) 端口 (40000-60000)
  newpass             重新生成 Hysteria2 认证密码
  newobfs             重新生成 Hysteria2 混淆密码
  info                显示当前配置与分享链接
  start               启动 hysteria2 与 anytls 服务
  stop                停止服务
  restart             重启服务
  status              查看服务运行状态
  help                显示本帮助

注: 端口范围强制 40000-60000, 且两协议端口不得相同 (同端口模式已移除)
HEOF
}

validate_port() {
  case "$1" in
    ''|*[!0-9]*)
      echo -e "${RED}错误: 端口必须是纯数字${PLAIN}"
      return 1
      ;;
  esac
  if [ "$1" -lt 40000 ] || [ "$1" -gt 60000 ]; then
    echo -e "${RED}错误: 端口必须在 40000-60000 范围内${PLAIN}"
    return 1
  fi
  return 0
}

# 端口占用检查: $1=udp|tcp $2=端口; 返回 0=空闲 1=被占
check_port_free() {
  case "$1" in
    udp) ss -Huln 2>/dev/null | awk '{print $4}' | grep -q ":$2\$" && return 1 ;;
    tcp) ss -Htln 2>/dev/null | awk '{print $4}' | grep -q ":$2\$" && return 1 ;;
  esac
  return 0
}

print_links() {
  echo ""
  echo -e "${GREEN}=== 当前配置 (分离端口) ===${PLAIN}"
  echo -e " 服务器地址    : ${CYAN}${SERVER_IP}${PLAIN}"
  echo -e " Hy2 端口     : ${CYAN}${HY_PORT}${PLAIN} (UDP)"
  echo -e " AnyTLS 端口  : ${CYAN}${ATLS_PORT}${PLAIN} (TCP)"
  echo -e " 伪装 SNI     : ${CYAN}${HY_SNI}${PLAIN}"
  echo -e " Hy2 认证     : ${CYAN}${HY_PASS}${PLAIN}"
  echo -e " Hy2 obfs     : ${CYAN}gecko / ${HY_OBFS_PASS}${PLAIN}"
  echo -e " Hy2 pin      : ${CYAN}${HY_PIN}${PLAIN}"
  echo -e " AnyTLS 密码  : ${CYAN}${ATLS_PASS}${PLAIN}"
  echo ""
  echo -e "${YELLOW}[Hysteria2 链接]${PLAIN}"
  echo -e "${CYAN}hy2://${HY_PASS}@${SERVER_IP}:${HY_PORT}?pinSHA256=${HY_PIN}&sni=${HY_SNI}&obfs=gecko&obfs-password=${HY_OBFS_PASS}#Hy2-Gecko${PLAIN}"
  echo ""
  echo -e "${YELLOW}[AnyTLS 链接]${PLAIN}"
  echo -e "${CYAN}anytls://${ATLS_PASS}@${SERVER_IP}:${ATLS_PORT}?sni=${HY_SNI}&insecure=1#AnyTLS${PLAIN}"
  echo ""
}

do_set_hy2() {
  NEW_PORT=$1
  if [ "$NEW_PORT" = "$HY_PORT" ]; then
    echo "Hysteria2 端口已是 ${NEW_PORT}，无需修改"
    return 0
  fi
  if [ "$NEW_PORT" = "$ATLS_PORT" ]; then
    echo -e "${RED}错误: 端口 ${NEW_PORT} 是 AnyTLS 当前端口, 两协议端口不得相同${PLAIN}"
    return 1
  fi
  if ! check_port_free udp "$NEW_PORT"; then
    echo -e "${RED}错误: UDP 端口 ${NEW_PORT} 已被其他进程占用${PLAIN}"
    return 1
  fi
  sed -i "s|^listen:.*|listen: :${NEW_PORT}|" "$HY_CONFIG"
  sed -i "s|^HY_PORT=.*|HY_PORT=${NEW_PORT}|" "$INFO_ENV"
  rc-service hysteria2 restart >/dev/null 2>&1
  . "$INFO_ENV"
  echo -e "${GREEN}✔ Hysteria2 端口已更新为 ${NEW_PORT} (UDP)${PLAIN}"
  print_links
}

do_set_anytls() {
  NEW_PORT=$1
  if [ ! -f /etc/init.d/anytls ]; then
    echo -e "${RED}错误: AnyTLS 未安装，无法修改其端口${PLAIN}"
    return 1
  fi
  if [ "$NEW_PORT" = "$ATLS_PORT" ]; then
    echo "AnyTLS 端口已是 ${NEW_PORT}，无需修改"
    return 0
  fi
  if [ "$NEW_PORT" = "$HY_PORT" ]; then
    echo -e "${RED}错误: 端口 ${NEW_PORT} 是 Hysteria2 当前端口, 两协议端口不得相同${PLAIN}"
    return 1
  fi
  if ! check_port_free tcp "$NEW_PORT"; then
    echo -e "${RED}错误: TCP 端口 ${NEW_PORT} 已被其他进程占用${PLAIN}"
    return 1
  fi
  sed -i "s|^ATLS_PORT=.*|ATLS_PORT=${NEW_PORT}|" "$INFO_ENV"
  rc-service anytls restart >/dev/null 2>&1
  . "$INFO_ENV"
  echo -e "${GREEN}✔ AnyTLS 端口已更新为 ${NEW_PORT} (TCP)${PLAIN}"
  print_links
}

cmd_set() {
  if [ $# -ne 2 ]; then
    echo -e "${RED}错误: 参数不足${PLAIN}"
    echo "用法: hys set <hy2|anytls> <port>"
    return 1
  fi
  case "$1" in
    hy2)    validate_port "$2" && do_set_hy2 "$2" ;;
    anytls) validate_port "$2" && do_set_anytls "$2" ;;
    *)
      echo -e "${RED}错误: 未知目标 '$1'，可用值: hy2 / anytls${PLAIN}"
      echo "用法: hys set <hy2|anytls> <port>"
      return 1
      ;;
  esac
}

cmd_newpass() {
  NEW_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
  sed -i "s|^HY_PASS=.*|HY_PASS=${NEW_PASS}|" "$INFO_ENV"
  # auth 段 password 为 2 空格缩进, obfs 段为 4 空格缩进, 不会误替换
  sed -i "s|^  password: .*|  password: ${NEW_PASS}|" "$HY_CONFIG"
  rc-service hysteria2 restart >/dev/null 2>&1
  . "$INFO_ENV"
  echo -e "${GREEN}✔ Hysteria2 认证密码已更新${PLAIN}"
  print_links
}

cmd_newobfs() {
  NEW_OBFS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
  sed -i "s|^HY_OBFS_PASS=.*|HY_OBFS_PASS=${NEW_OBFS}|" "$INFO_ENV"
  sed -i "s|^    password: .*|    password: ${NEW_OBFS}|" "$HY_CONFIG"
  rc-service hysteria2 restart >/dev/null 2>&1
  . "$INFO_ENV"
  echo -e "${GREEN}✔ Hysteria2 混淆密码已更新${PLAIN}"
  print_links
}

cmd_start() {
  rc-service hysteria2 start
  [ -f /etc/init.d/anytls ] && rc-service anytls start
}

cmd_stop() {
  rc-service hysteria2 stop 2>/dev/null
  [ -f /etc/init.d/anytls ] && rc-service anytls stop 2>/dev/null
}

cmd_restart() {
  rc-service hysteria2 restart
  [ -f /etc/init.d/anytls ] && rc-service anytls restart
}

cmd_status() {
  rc-service hysteria2 status
  [ -f /etc/init.d/anytls ] && rc-service anytls status
}

case "$1" in
  set)      shift; cmd_set "$@" ;;
  newpass)  cmd_newpass ;;
  newobfs)  cmd_newobfs ;;
  info)     print_links ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  restart)  cmd_restart ;;
  status)   cmd_status ;;
  help|-h|--help|"") print_help ;;
  *)        echo "未知子命令: $1"; print_help; exit 1 ;;
esac
HYSEOF
chmod 755 /usr/local/bin/hys

# ===== [7/7] 启动服务并输出结果 =====
echo -e "${YELLOW}[7/7] 启动服务...${PLAIN}"

pkill -f "^/usr/local/bin/hysteria server" 2>/dev/null || true
if [ "$INSTALL_ATLS" = "1" ]; then
  pkill -f "^/usr/local/bin/anytls-server -l" 2>/dev/null || true
fi
rc-service hysteria2 stop 2>/dev/null || true
[ "$INSTALL_ATLS" = "1" ] && rc-service anytls stop 2>/dev/null || true
sleep 1

rc-update add hysteria2 default
rc-service hysteria2 start

if [ "$INSTALL_ATLS" = "1" ]; then
  rc-update add anytls default
  rc-service anytls start
fi

sleep 2
rc-service hysteria2 status || true
[ "$INSTALL_ATLS" = "1" ] && rc-service anytls status || true

echo -e "\n${GREEN}================================================================${PLAIN}"
echo -e "${GREEN}🎉 双协议部署成功！(分离端口模式)${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e " 📍 服务器地址        : ${CYAN}${SERVER_IP}${PLAIN}"
echo -e " 🔢 Hysteria2 端口    : ${CYAN}${HY_PORT}${PLAIN} (UDP)"
echo -e " 🔢 AnyTLS 端口       : ${CYAN}${ATLS_PORT}${PLAIN} (TCP)"
echo -e " 🌐 伪装 SNI          : ${CYAN}${OPTIMIZED_SNI}${PLAIN}"
echo -e " 🔐 Hy2 指纹          : ${CYAN}${PIN_SHA256}${PLAIN}"
echo -e "----------------------------------------------------------------"
echo -e " [1] Hysteria 2 (Gecko)"
echo -e "   - 认证密码 : ${CYAN}${HY_PASS}${PLAIN}"
echo -e "   - 混淆密码 : ${CYAN}${HY_OBFS_PASS}${PLAIN}"
echo -e "----------------------------------------------------------------"
if [ "$INSTALL_ATLS" = "1" ]; then
  echo -e " [2] AnyTLS"
  echo -e "   - 认证密码 : ${CYAN}${ATLS_PASS}${PLAIN}"
  echo -e "----------------------------------------------------------------"
fi
echo -e "${YELLOW}[Hysteria 2 直连链接]${PLAIN}"
echo -e "${CYAN}hy2://${HY_PASS}@${SERVER_IP}:${HY_PORT}?pinSHA256=${PIN_SHA256}&sni=${OPTIMIZED_SNI}&obfs=gecko&obfs-password=${HY_OBFS_PASS}#Hy2-Gecko${PLAIN}"
if [ "$INSTALL_ATLS" = "1" ]; then
  echo -e "\n${YELLOW}[AnyTLS 直连链接]${PLAIN}"
  echo -e "${CYAN}anytls://${ATLS_PASS}@${SERVER_IP}:${ATLS_PORT}?sni=${OPTIMIZED_SNI}&insecure=1#AnyTLS${PLAIN}"
fi
echo -e "${GREEN}================================================================${PLAIN}"
echo -e "${YELLOW}[后续管理命令]${PLAIN}"
echo -e "  hys set hy2 51234      # 只改 Hysteria2 (UDP) 端口"
echo -e "  hys set anytls 51567   # 只改 AnyTLS (TCP) 端口"
echo -e "  hys info               # 查看当前配置与分享链接"
echo -e "  hys newpass            # 重生成 Hysteria2 认证密码"
echo -e "  hys newobfs            # 重生成 Hysteria2 混淆密码"
echo -e "  hys restart            # 重启服务"
echo -e "  hys status             # 查看服务状态"
echo -e "${GREEN}================================================================${PLAIN}"
