#!/bin/sh
# =========================================================================
# Hysteria 2 (Gecko) + AnyTLS 双端口部署脚本（Alpine 3.20+/Podman/Docker/原生）
#
# 与旧版（同端口方案）的关键区别:
#   1) HY2 监听 -p 指定端口; AnyTLS 监听 -a 指定端口（默认 = HY2 端口 +1）。
#      原因: Hysteria2 与 AnyTLS 都跑在 QUIC(UDP) 上, 同一个 UDP 端口只能被一个
#      socket 绑定, 谁先启动谁占住端口, 后启动的直接 bind 失败 -> 表现就是
#      "HY2 通、AnyTLS 完全不通"。
#   2) AnyTLS 改为正规 YAML 配置 + -c 启动, 失败时自动回退命令行参数模式并复检。
#   3) AnyTLS 下载名兼容修正: API 资产名宽松匹配 + latest/download 兜底名 +
#      嵌套目录/zip 与 tar.gz 双解包 + 二进制可运行性校验。
#
# 用法: sh ah2-hy2-anytls-dualport.sh [选项]
#   -p <端口>     HY2 监听端口（默认随机高位端口）
#   -a <端口>     AnyTLS 监听端口（默认 = HY2 端口 +1）
#   -i <公网IP>   手动指定服务器公网 IP
#   -s <域名>     手动指定伪装 SNI（默认自动测速优选）
#   -h            显示帮助
# 例: curl -fsSL <脚本地址> | bash -s -- -p 52048 -i 152.175.146.111
#     （AnyTLS 自动使用 52049）
# =========================================================================

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'
log_i() { printf "${GREEN}[OK]${PLAIN} %s\n" "$1"; }
log_w() { printf "${YELLOW}[!!]${PLAIN} %s\n" "$1"; }
log_e() { printf "${RED}[XX]${PLAIN} %s\n" "$1"; }
log_s() { printf "${YELLOW}%s${PLAIN}\n" "$1"; }

CUSTOM_PORT=""; CUSTOM_ATLS=""; CUSTOM_IP=""; CUSTOM_SNI=""

usage() {
  printf '用法: %s [-p HY2端口] [-a AnyTLS端口] [-i 公网IP] [-s SNI域名] [-h]\n' "$0"
}

while getopts "p:a:i:s:h" opt; do
  case "$opt" in
    p) CUSTOM_PORT="$OPTARG" ;;
    a) CUSTOM_ATLS="$OPTARG" ;;
    i) CUSTOM_IP="$OPTARG" ;;
    s) CUSTOM_SNI="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

[ "$(id -u)" = "0" ] || { log_e "请使用 root 权限运行本脚本"; exit 1; }

log_s "=== 部署 Hysteria 2 (Gecko) + AnyTLS 双端口版 ==="

# ===== [1/6] 基础环境 =====
log_s "[1/6] 检查系统环境..."
if ! command -v apk >/dev/null 2>&1; then
  log_e "未检测到 apk，本脚本仅支持 Alpine Linux"; exit 1
fi
if [ ! -s /etc/resolv.conf ] || ! grep -q 'nameserver' /etc/resolv.conf 2>/dev/null; then
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
fi
apk update || true
apk add --no-cache curl openssl ca-certificates gawk iproute2 unzip >/dev/null || {
  log_e "依赖安装失败（apk add）"; exit 1; }
apk add --no-cache tar >/dev/null 2>&1 || true

# ===== [2/6] 端口 / 密钥 =====
log_s "[2/6] 初始化端口与密钥..."
is_num() { printf '%s' "$1" | grep -qE '^[0-9]+$'; }
in_range() { is_num "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65534 ]; }

if [ -n "$CUSTOM_PORT" ]; then
  in_range "$CUSTOM_PORT" || { log_e "非法端口: $CUSTOM_PORT"; exit 1; }
  PORT="$CUSTOM_PORT"
else
  PORT=$(awk 'BEGIN{srand(); print int(rand()*45000)+10000')
fi

if [ -n "$CUSTOM_ATLS" ]; then
  in_range "$CUSTOM_ATLS" || { log_e "非法端口: $CUSTOM_ATLS"; exit 1; }
  ATLS_PORT="$CUSTOM_ATLS"
else
  ATLS_PORT=$((PORT + 1))
fi
[ "$PORT" != "$ATLS_PORT" ] || { log_e "HY2 与 AnyTLS 端口不能相同（QUIC 单端口互斥）"; exit 1; }

udp_in_use() {
  ss -lun 2>/dev/null | awk -v p="$1" 'BEGIN{r="[:.]" p "([^0-9]|$)"}
    { for (i = 1; i <= NF; i++) if ($i ~ r) found = 1 }
    END{ exit found ? 0 : 1 }'
}
for _p in "$PORT" "$ATLS_PORT"; do
  if udp_in_use "$_p"; then
    log_w "端口 $_p 上已有 UDP 监听，可能与其它服务冲突（继续部署，若连接失败请先排查）"
  fi
done

HY_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)
HY_OBFS_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)
ATLS_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)

ARCH_STR=$(uname -m); case "$ARCH_STR" in
  x86_64|amd64) ARCH_STR='amd64' ;;
  aarch64|arm64) ARCH_STR='arm64' ;;
  armv7l|arm) ARCH_STR='arm' ;;
  *) ARCH_STR='amd64' ;;
esac

mkdir -p /etc/hysteria /etc/anytls /usr/local/bin /var/log
chmod 700 /etc/hysteria /etc/anytls

# 通用下载（原站 + 两个国内加速前缀）
fetch() {
  _url="$1"; _dst="$2"; _m=0
  while [ "$_m" -lt 3 ]; do
    case "$_m" in
      0) _try="$_url" ;;
      1) _try="https://ghfast.top/$_url" ;;
      2) _try="https://gh-proxy.com/$_url" ;;
    esac
    if curl -fL --retry 1 --connect-timeout 8 --max-time 90 -o "$_dst" "$_try" 2>/dev/null && [ -s "$_dst" ]; then
      return 0
    fi
    rm -f "$_dst" 2>/dev/null
    _m=$((_m + 1))
  done
  return 1
}

# ===== [3/6] 下载 Hysteria 2 =====
log_s "[3/6] 下载 Hysteria 2..."
rm -f /tmp/hy.bin
fetch "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH_STR}" /tmp/hy.bin \
  || { log_e "Hysteria 2 下载失败，请检查服务器出网/时间同步"; exit 1; }
DISGUISE_HY='systemd-timesyncd'
mv -f /tmp/hy.bin "/usr/local/bin/$DISGUISE_HY"; chmod +x "/usr/local/bin/$DISGUISE_HY"
log_i "Hysteria 2 就绪（进程名伪装: $DISGUISE_HY）"

# ===== [4/6] 下载 AnyTLS（资产名兼容） =====
log_s "[4/6] 下载 AnyTLS 核心（多资产名兼容）..."
ATLS_REPO='anytls/anytls-go'
INSTALL_ATLS=0; ATLS_BIN_PATH=''

extract_pkg() {
  _pkg="$1"; _out="$2"
  rm -rf "$_out"; mkdir -p "$_out"
  _magic=$(od -An -tx1 -N2 "$_pkg" 2>/dev/null | tr -d ' \n')
  if [ "$_magic" = '504b' ]; then
    unzip -qo "$_pkg" -d "$_out" 2>/dev/null || return 1
  else
    tar -xzf "$_pkg" -C "$_out" 2>/dev/null || tar -xf "$_pkg" -C "$_out" 2>/dev/null || return 1
  fi
  return 0
}

# 解出来的包里挑服务端二进制，并做可运行性校验
pick_server_bin() {
  _out="$1"; _cand=''
  _cand=$(find "$_out" -type f \( -name 'anytls-server' -o -name 'anytls_server' \) 2>/dev/null | head -n 1)
  if [ -z "$_cand" ]; then
    _cand=$(find "$_out" -type f -name 'anytls*' ! -name '*client*' 2>/dev/null | head -n 1)
  fi
  [ -n "$_cand" ] || return 1
  chmod +x "$_cand" 2>/dev/null
  _help=$( ("$_cand" -h 2>&1 || true) | head -c 400 )
  case "$_help" in
    *nytls*|*assword*|*listen*|*Usage*|*usage*) return 0 ;;
  esac
  _help=$( ("$_cand" --version 2>&1 || true) | head -c 400 )
  case "$_help" in
    *nytls*|*[0-9]*) return 0 ;;
  esac
  return 1
}

try_atls_pkg() {   # $1 = 下载 URL
  [ "$INSTALL_ATLS" = 1 ] && return 0
  rm -f /tmp/anytls_pkg
  fetch "$1" /tmp/anytls_pkg || return 1
  extract_pkg /tmp/anytls_pkg /tmp/anytls_x || return 1
  if pick_server_bin /tmp/anytls_x; then
    ATLS_BIN_PATH=$(find /tmp/anytls_x -type f \( -name 'anytls-server' -o -name 'anytls_server' -o -name 'anytls*' \) ! -name '*client*' 2>/dev/null | head -n 1)
    [ -n "$ATLS_BIN_PATH" ] || return 1
    INSTALL_ATLS=1
    log_i "AnyTLS 核心获取成功: $1"
    return 0
  fi
  return 1
}

# 4.1 走 GitHub API 宽松匹配资产名（不再要求 linux_${ARCH}.zip 精确形式）
ATLS_JSON=$(curl -fsSL --max-time 20 -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$ATLS_REPO/releases/latest" 2>/dev/null || true)
ATLS_URLS=$(printf '%s' "$ATLS_JSON" | tr ',' '\n' | grep 'browser_download_url' | grep -oE 'https?://[^"]+')
if [ -n "$ATLS_URLS" ]; then
  ATLS_CAND=$(printf '%s\n' "$ATLS_URLS" \
    | grep -iE '\.(zip|tar\.gz|tgz)$' \
    | grep -viE 'client|windows|darwin|freebsd|386|armv6|riscv|mips|loong' \
    | grep -iE "linux[_-]?${ARCH_STR}|${ARCH_STR}[_-]?linux|amd64|x86[_-]?64")
  ATLS_SERVER_FIRST=$(printf '%s\n' "$ATLS_CAND" | grep -i 'server')
  for _u in $ATLS_SERVER_FIRST $ATLS_CAND; do try_atls_pkg "$_u" && break; done
else
  log_w "GitHub API 未返回资产列表（多为匿名限流 403），改用固定资产名兜底"
fi

# 4.2 固定资产名兜底（覆盖常见命名习惯）
if [ "$INSTALL_ATLS" != 1 ]; then
  for _n in \
    "anytls-server-linux-${ARCH_STR}.zip" "anytls-server_linux_${ARCH_STR}.zip" \
    "anytls-server-${ARCH_STR}-linux.zip" "anytls-linux-${ARCH_STR}.zip" \
    "anytls_linux_${ARCH_STR}.zip" "anytls-linux-${ARCH_STR}.tar.gz" \
    "anytls_linux_${ARCH_STR}.tar.gz"; do
    try_atls_pkg "https://github.com/$ATLS_REPO/releases/latest/download/$_n" && break
  done
fi

if [ "$INSTALL_ATLS" = 1 ]; then
  DISGUISE_ATLS='systemd-networkd'
  mv -f "$ATLS_BIN_PATH" "/usr/local/bin/$DISGUISE_ATLS"
  chmod +x "/usr/local/bin/$DISGUISE_ATLS"
  log_i "AnyTLS 就绪（进程名伪装: $DISGUISE_ATLS）"
else
  log_w "AnyTLS 核心下载失败，本轮仅部署 Hysteria 2（可重跑脚本或换出网线路）"
fi

# ===== [5/6] SNI 优选 + 证书 + 配置 =====
log_s "[5/6] 优选 SNI、生成证书与配置..."
if [ -n "$CUSTOM_SNI" ]; then
  OPT_SNI="$CUSTOM_SNI"
else
  OPT_SNI='www.bing.com'; LOWEST=9999
  for d in www.amd.com www.apple.com www.microsoft.com www.samsung.com www.sony.com www.oracle.com www.bing.com; do
    lat=$(curl -o /dev/null -s -w '%{time_connect}\n' --connect-timeout 2 -m 3 "https://$d" 2>/dev/null || echo 999)
    better=$(awk -v l="$lat" -v m="$LOWEST" 'BEGIN{print (l>0 && l<m)?1:0}')
    [ "$better" = 1 ] && { LOWEST=$lat; OPT_SNI=$d; }
  done
fi

CERT=/etc/hysteria/cert.crt; KEY=/etc/hysteria/key.key
rm -f "$CERT" "$KEY"
openssl ecparam -name prime256v1 -genkey -noout -out "$KEY" 2>/dev/null
openssl req -new -x509 -sha256 -days 3650 -key "$KEY" -out "$CERT" -subj "/CN=${OPT_SNI}" 2>/dev/null
[ -s "$CERT" ] && [ -s "$KEY" ] || { log_e "自签证书生成失败"; exit 1; }
chmod 600 "$KEY"; ln -sf "$CERT" /etc/anytls/cert.crt; ln -sf "$KEY" /etc/anytls/key.key

cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}
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
    url: https://${OPT_SNI}
    rewriteHost: true
tls:
  cert: ${CERT}
  key: ${KEY}
EOF

# AnyTLS 正规 YAML 配置（-c 启动）；若该版本不认此字段，脚本会自动回退 -l/-p
cat > /etc/anytls/config.yaml <<EOF
listen: "0.0.0.0:${ATLS_PORT}"
password:
  - "${ATLS_PASS}"
tls:
  certificate: ${CERT}
  key: ${KEY}
log:
  level: info
EOF

# ===== [6/6] 启动与自检 =====
log_s "[6/6] 启动服务并自检..."
pkill -x "$DISGUISE_HY" 2>/dev/null || true
[ "$INSTALL_ATLS" = 1 ] && { pkill -x "$DISGUISE_ATLS" 2>/dev/null || true; }
sleep 1

nohup "/usr/local/bin/$DISGUISE_HY" server -c /etc/hysteria/config.yaml >/var/log/hysteria.log 2>&1 &
HY_PID=$!
sleep 3
HY_OK=0
kill -0 "$HY_PID" 2>/dev/null && HY_OK=1

ATLS_MODE=''; ATLS_PID=''
if [ "$INSTALL_ATLS" = 1 ]; then
  nohup "/usr/local/bin/$DISGUISE_ATLS" -c /etc/anytls/config.yaml >/var/log/anytls.log 2>&1 &
  ATLS_PID=$!
  sleep 3
  if kill -0 "$ATLS_PID" 2>/dev/null; then
    ATLS_MODE='yaml'
  else
    log_w "AnyTLS YAML 模式未被该版本接受，自动回退命令行参数模式"
    nohup "/usr/local/bin/$DISGUISE_ATLS" -l "0.0.0.0:${ATLS_PORT}" -p "$ATLS_PASS" >/var/log/anytls.log 2>&1 &
    ATLS_PID=$!
    sleep 3
    kill -0 "$ATLS_PID" 2>/dev/null && ATLS_MODE='flags'
  fi
fi

SERVER_IP="$CUSTOM_IP"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 5 api.ipify.org || curl -4s --max-time 5 ifconfig.me || echo 'YOUR_SERVER_IP')
fi

printf '\n%s================================================================%s\n' "$GREEN" "$PLAIN"
printf ' 双端口部署完成 (HY2 + AnyTLS)\n'
printf '%s================================================================%s\n' "$GREEN" "$PLAIN"
printf '  服务器地址      : %s%s%s\n' "$CYAN" "$SERVER_IP" "$PLAIN"
printf '  HY2  端口      : %s%s%s   (UDP/QUIC)\n' "$CYAN" "$PORT" "$PLAIN"
printf '  AnyTLS 端口    : %s%s%s   (UDP/QUIC, 独立端口)\n' "$CYAN" "$ATLS_PORT" "$PLAIN"
printf '  伪装 SNI       : %s%s%s\n' "$CYAN" "$OPT_SNI" "$PLAIN"
printf '  ---------------------------------------------------------\n'
printf '  [1] Hysteria2 (gecko)  密码 %s  混淆密码 %s\n' "$HY_PASS" "$HY_OBFS_PASS"
if [ "$ATLS_MODE" = 'yaml' ]; then
  printf '  [2] AnyTLS  密码 %s  (YAML 配置模式 /etc/anytls/config.yaml)\n' "$ATLS_PASS"
elif [ "$ATLS_MODE" = 'flags' ]; then
  printf '  [2] AnyTLS  密码 %s  (命令行参数模式, 该版本不支持自定义证书/SNI)\n' "$ATLS_PASS"
else
  printf '  [2] AnyTLS  未运行 (下载失败或启动失败, 见 /var/log/anytls.log)\n'
fi
printf '  ---------------------------------------------------------\n'
printf '%s[HY2 链接]%s\n' "$YELLOW" "$PLAIN"
printf '%shy2://%s@%s:%s?insecure=1&sni=%s&obfs=gecko&obfs-password=%s#Hy2-Gecko%s\n' \
  "$CYAN" "$HY_PASS" "$SERVER_IP" "$PORT" "$OPT_SNI" "$HY_OBFS_PASS" "$PLAIN"
if [ -n "$ATLS_MODE" ]; then
  printf '%s[AnyTLS 链接]%s\n' "$YELLOW" "$PLAIN"
  if [ "$ATLS_MODE" = 'yaml' ]; then
    printf '%sanytls://%s@%s:%s?sni=%s&insecure=1#AnyTLS%s\n' "$CYAN" "$ATLS_PASS" "$SERVER_IP" "$ATLS_PORT" "$OPT_SNI" "$PLAIN"
  else
    printf '%sanytls://%s@%s:%s#AnyTLS%s\n' "$CYAN" "$ATLS_PASS" "$SERVER_IP" "$ATLS_PORT" "$PLAIN"
  fi
  printf '  mihomo/Clash Meta 片段:\n'
  printf '    - name: "AnyTLS-%s"\n' "$ATLS_PORT"
  printf '      type: anytls\n'
  printf '      server: %s\n' "$SERVER_IP"
  printf '      port: %s\n' "$ATLS_PORT"
  printf '      password: "%s"\n' "$ATLS_PASS"
  printf '      tls: true\n'
  printf '      skip-cert-verify: true\n'
  [ "$ATLS_MODE" = 'yaml' ] && printf '      sni: %s\n' "$OPT_SNI"
fi
printf '%s================================================================%s\n' "$GREEN" "$PLAIN"

# 自检结果
printf '\n监听状态核查:\n'
ss -lunp 2>/dev/null | grep -E "[:.]($PORT|$ATLS_PORT)([^0-9]|$)" || log_w "ss 未看到监听端口，请检查防火墙/安全组与 /var/log 日志"
[ "$HY_OK" = 1 ] && log_i "HY2 进程存活 (pid $HY_PID)" || { log_e "HY2 启动失败，日志尾部:"; tail -n 15 /var/log/hysteria.log 2>/dev/null; }
if [ -n "$ATLS_MODE" ]; then
  log_i "AnyTLS 进程存活 (pid $ATLS_PID, 模式 $ATLS_MODE)"
elif [ "$INSTALL_ATLS" = 1 ]; then
  log_e "AnyTLS 启动失败，日志尾部:"; tail -n 15 /var/log/anytls.log 2>/dev/null
fi

{
  echo "HY2  : ${SERVER_IP}:${PORT} pass=${HY_PASS} obfs=gecko obfs-pass=${HY_OBFS_PASS} sni=${OPT_SNI}"
  if [ -n "$ATLS_MODE" ]; then
    echo "ATLS : ${SERVER_IP}:${ATLS_PORT} pass=${ATLS_PASS} mode=${ATLS_MODE} sni=${OPT_SNI}"
  fi
} > /etc/hysteria/client-info.txt
chmod 600 /etc/hysteria/client-info.txt
log_i '凭据已备份至 /etc/hysteria/client-info.txt'
log_w '记得在 VPS 安全组/防火墙放行 UDP 与 TCP 两个端口（QUIC 走 UDP）'
