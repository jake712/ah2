cat <<'EOF' > /tmp/al-obfs-v7.sh
#!/bin/sh
# =========================================================================
# Hysteria 2 (Gecko) + VLESS (XTLS-Reality) Alpine 同端口部署脚本
# 适配: Alpine Linux 3.20/3.21/3.22+, OpenRC / 容器环境
# =========================================================================

set -eu
umask 077

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CUSTOM_PORT=""
CUSTOM_IP=""
ALLOW_MIRROR=0
FORCE_OVERWRITE=0

usage() {
  printf "用法: %s [选项]\n" "$0"
  printf "  -p <端口>   指定监听端口 (1-65535，默认随机高位端口)\n"
  printf "  -i <公网IP> 指定服务器公网 IP (支持 IPv4 / IPv6)\n"
  printf "  -m          主站下载失败时允许使用第三方镜像站 (供应链风险自负)\n"
  printf "  -F          强制覆盖已存在的密钥与配置文件\n"
  printf "  -h          显示帮助信息\n"
}

is_valid_port() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_valid_octet() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 0 ] && [ "$1" -le 255 ]
}

is_valid_ip() {
  ip="${1:-}"
  if printf '%s' "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    o1=$(printf '%s' "$ip" | cut -d. -f1)
    o2=$(printf '%s' "$ip" | cut -d. -f2)
    o3=$(printf '%s' "$ip" | cut -d. -f3)
    o4=$(printf '%s' "$ip" | cut -d. -f4)
    is_valid_octet "$o1" && is_valid_octet "$o2" && is_valid_octet "$o3" && is_valid_octet "$o4"
    return $?
  fi
  if printf '%s' "$ip" | grep -Eq '^[0-9A-Fa-f:]+$'; then
    case "$ip" in
      *:*) return 0 ;;
    esac
  fi
  return 1
}

is_port_in_use() {
  p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -lntu "sport = :$p" 2>/dev/null | grep -q .
    return $?
  fi
  return 1
}

verify_binary() {
  bin_path="$1"
  name="$2"
  [ -s "$bin_path" ] || return 1
  if head -n 5 "$bin_path" 2>/dev/null | grep -qiE '<!doctype html|<html'; then
    printf "%b错误: %s 下载内容疑似 HTML 错误页%b\n" "$RED" "$name" "$PLAIN" >&2
    return 1
  fi
  chmod 755 "$bin_path"
  "$bin_path" version >/dev/null 2>&1 || "$bin_path" -v >/dev/null 2>&1 || return 1
  return 0
}

verify_sha256_if_available() {
  file_path="$1"
  sums_url="$2"
  asset_name="$3"
  tmp_sums="/tmp/release_sums.$$"
  rm -f "$tmp_sums"
  if curl -fsSL --max-time 15 -o "$tmp_sums" "$sums_url" 2>/dev/null && [ -s "$tmp_sums" ]; then
    expected=$(awk -v target="$asset_name" '$2 ~ ("(^|/)" target "$") {print $1; exit}' "$tmp_sums")
    rm -f "$tmp_sums"
    if [ -n "$expected" ] && command -v sha256sum >/dev/null 2>&1; then
      actual=$(sha256sum "$file_path" | awk '{print $1}')
      if [ "$actual" != "$expected" ]; then
        printf "%b错误: %s SHA-256 校验失败%b\n" "$RED" "$asset_name" "$PLAIN" >&2
        return 1
      fi
    fi
  else
    rm -f "$tmp_sums"
  fi
  return 0
}

while getopts "p:i:mFh" opt; do
  case "$opt" in
    p) CUSTOM_PORT=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    m) ALLOW_MIRROR=1 ;;
    F) FORCE_OVERWRITE=1 ;;
    h) usage; exit 0 ;;
    \?) usage >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  printf "%b错误: 请使用 root 权限运行此脚本！%b\n" "$RED" "$PLAIN" >&2
  exit 1
fi

if [ -n "$CUSTOM_PORT" ] && ! is_valid_port "$CUSTOM_PORT"; then
  printf "%b错误: 无效的端口号 '%s' (需为 1-65535 的整数)%b\n" "$RED" "$CUSTOM_PORT" "$PLAIN" >&2
  exit 1
fi

if [ -n "$CUSTOM_IP" ] && ! is_valid_ip "$CUSTOM_IP"; then
  printf "%b错误: 无效的 IP 地址 '%s'%b\n" "$RED" "$CUSTOM_IP" "$PLAIN" >&2
  exit 1
fi

printf "%b=== 开始部署 Hysteria 2 (Gecko) + VLESS-Reality (同端口双协议) ===%b\n" "$GREEN" "$PLAIN"

# ===== [1/6] 基础环境与依赖 =====
printf "%b[1/6] 检查并配置系统环境...%b\n" "$YELLOW" "$PLAIN"
if ! command -v apk >/dev/null 2>&1; then
  printf "%b错误: 未检测到 apk 包管理器，本脚本仅支持 Alpine Linux%b\n" "$RED" "$PLAIN" >&2
  exit 1
fi

if ! curl -fsI --max-time 5 https://api.github.com >/dev/null 2>&1; then
  if [ -w /etc/resolv.conf ]; then
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf || true
  else
    printf "%b提示: /etc/resolv.conf 不可写，若解析失败请检查容器或宿主机 DNS%b\n" "$YELLOW" "$PLAIN"
  fi
fi

apk update -q
apk add --no-cache curl openssl ca-certificates gawk iproute2 unzip

# ===== [2/6] 架构、端口与密钥初始化 =====
printf "%b[2/6] 检查架构、端口与安全密钥...%b\n" "$YELLOW" "$PLAIN"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)
    HY_ARCH="amd64"
    XRAY_ARCH="64"
    ;;
  aarch64|arm64)
    HY_ARCH="arm64"
    XRAY_ARCH="arm64-v8a"
    ;;
  *)
    printf "%b错误: 不支持的 CPU 架构 '%s' (仅支持 amd64/x86_64 与 arm64/aarch64)%b\n" "$RED" "$ARCH" "$PLAIN" >&2
    exit 1
    ;;
esac

mkdir -p /etc/hysteria /etc/xray /usr/local/bin /var/log /var/run
chmod 700 /etc/hysteria /etc/xray

STATE_FILE="/etc/hysteria/deploy.env"
if [ -f "$STATE_FILE" ] && [ "$FORCE_OVERWRITE" -ne 1 ]; then
  printf "%b检测到已有部署记录 (%s)，保留现有密钥与端口 (如需重新生成请加 -F)%b\n" "$YELLOW" "$STATE_FILE" "$PLAIN"
  # shellcheck disable=SC1090
  . "$STATE_FILE"
fi

if [ -n "$CUSTOM_PORT" ]; then
  PORT="$CUSTOM_PORT"
elif [ -z "${PORT:-}" ]; then
  seed=$(($(date +%s) + $$))
  PORT=$(awk -v s="$seed" 'BEGIN{srand(s); print int(rand()*(55000-10000+1))+10000}')
fi

if ! is_valid_port "$PORT"; then
  printf "%b错误: 端口配置异常: %s%b\n" "$RED" "$PORT" "$PLAIN" >&2
  exit 1
fi

HY_PID_FILE="/var/run/hysteria2.pid"
XRAY_PID_FILE="/var/run/xray-vless.pid"
OLD_HY_PID=""
OLD_XRAY_PID=""
[ -s "$HY_PID_FILE" ] && OLD_HY_PID=$(cat "$HY_PID_FILE" 2>/dev/null || true)
[ -s "$XRAY_PID_FILE" ] && OLD_XRAY_PID=$(cat "$XRAY_PID_FILE" 2>/dev/null || true)

if is_port_in_use "$PORT"; then
  occ_pids=$(ss -H -lntup "sport = :$PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | sort -u)
  for p in $occ_pids; do
    if [ "$p" != "$OLD_HY_PID" ] && [ "$p" != "$OLD_XRAY_PID" ]; then
      printf "%b错误: 端口 %s 已被其他进程 (PID %s) 占用%b\n" "$RED" "$PORT" "$p" "$PLAIN" >&2
      exit 1
    fi
  done
fi

HY_PASS="${HY_PASS:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 16)}"
HY_OBFS_PASS="${HY_OBFS_PASS:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 16)}"
VLESS_SHORT_ID="${VLESS_SHORT_ID:-$(openssl rand -hex 4)}"
VLESS_UUID="${VLESS_UUID:-}"
VLESS_PRIV_KEY="${VLESS_PRIV_KEY:-}"
VLESS_PUB_KEY="${VLESS_PUB_KEY:-}"

# ===== [3/6] 下载与校验核心组件 =====
printf "%b[3/6] 下载并校验 Hysteria 2 与 Xray-core...%b\n" "$YELLOW" "$PLAIN"

HY_ASSET="hysteria-linux-${HY_ARCH}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/${HY_ASSET}"
HY_SUMS_URL="https://github.com/apernet/hysteria/releases/latest/download/SHA256SUMS"
HY_TMP="/tmp/hysteria.$$"
rm -f "$HY_TMP"

hy_ok=0
if curl -fsSL --max-time 40 -o "$HY_TMP" "$HY_URL" && verify_sha256_if_available "$HY_TMP" "$HY_SUMS_URL" "$HY_ASSET" && verify_binary "$HY_TMP" "Hysteria 2"; then
  hy_ok=1
elif [ "$ALLOW_MIRROR" -eq 1 ]; then
  rm -f "$HY_TMP"
  if curl -fsSL --max-time 40 -o "$HY_TMP" "https://ghfast.top/$HY_URL" && verify_binary "$HY_TMP" "Hysteria 2 (Mirror)"; then
    hy_ok=1
  fi
fi

if [ "$hy_ok" -ne 1 ]; then
  rm -f "$HY_TMP"
  printf "%b错误: Hysteria 2 下载或校验失败%b\n" "$RED" "$PLAIN" >&2
  exit 1
fi
mv "$HY_TMP" /usr/local/bin/hysteria

XRAY_ASSET="Xray-linux-${XRAY_ARCH}.zip"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ASSET}"
XRAY_ZIP="/tmp/xray.$$.zip"
XRAY_DIR="/tmp/xray_extract.$$"
rm -rf "$XRAY_ZIP" "$XRAY_DIR"
mkdir -p "$XRAY_DIR"

xray_ok=0
if curl -fsSL --max-time 50 -o "$XRAY_ZIP" "$XRAY_URL" && [ -s "$XRAY_ZIP" ]; then
  if unzip -qo "$XRAY_ZIP" -d "$XRAY_DIR" && [ -s "$XRAY_DIR/xray" ] && verify_binary "$XRAY_DIR/xray" "Xray-core"; then
    xray_ok=1
  fi
elif [ "$ALLOW_MIRROR" -eq 1 ]; then
  rm -f "$XRAY_ZIP"
  if curl -fsSL --max-time 50 -o "$XRAY_ZIP" "https://ghfast.top/$XRAY_URL" && [ -s "$XRAY_ZIP" ]; then
    if unzip -qo "$XRAY_ZIP" -d "$XRAY_DIR" && [ -s "$XRAY_DIR/xray" ] && verify_binary "$XRAY_DIR/xray" "Xray-core (Mirror)"; then
      xray_ok=1
    fi
  fi
fi

INSTALL_VLESS=0
if [ "$xray_ok" -eq 1 ]; then
  mv "$XRAY_DIR/xray" /usr/local/bin/xray
  INSTALL_VLESS=1
else
  printf "%b警告: Xray-core 下载或校验失败，将仅部署 Hysteria 2%b\n" "$YELLOW" "$PLAIN"
fi
rm -rf "$XRAY_ZIP" "$XRAY_DIR"

# ===== [4/6] 校验 SNI 与生成配置 =====
printf "%b[4/6] 校验 TLS 1.3 SNI 并生成配置...%b\n" "$YELLOW" "$PLAIN"
SNI_CANDIDATES="www.microsoft.com www.apple.com www.amd.com www.oracle.com"
OPTIMIZED_SNI="${OPTIMIZED_SNI:-www.microsoft.com}"
BEST_TIME=9999

for domain in $SNI_CANDIDATES; do
  conn_time=$(curl -o /dev/null -s --tlsv1.3 -w '%{time_connect}\n' --connect-timeout 2 -m 4 "https://$domain" 2>/dev/null || echo "999")
  if printf "" | openssl s_client -tls1_3 -servername "$domain" -connect "${domain}:443" >/dev/null 2>&1; then
    is_better=$(awk -v t="$conn_time" -v b="$BEST_TIME" 'BEGIN {if (t > 0 && t < b) print 1; else print 0}')
    if [ "$is_better" = "1" ]; then
      BEST_TIME="$conn_time"
      OPTIMIZED_SNI="$domain"
    fi
  fi
done

if [ ! -s /etc/hysteria/key.key ] || [ ! -s /etc/hysteria/cert.crt ] || [ "$FORCE_OVERWRITE" -eq 1 ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=${OPTIMIZED_SNI}" -days 3650
  chmod 600 /etc/hysteria/key.key
  chmod 644 /etc/hysteria/cert.crt
fi

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
    url: https://${OPTIMIZED_SNI}
    rewriteHost: true
tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
EOF
chmod 600 /etc/hysteria/config.yaml

if [ "$INSTALL_VLESS" -eq 1 ]; then
  if [ -z "${VLESS_UUID:-}" ] || [ -z "${VLESS_PRIV_KEY:-}" ] || [ -z "${VLESS_PUB_KEY:-}" ] || [ "$FORCE_OVERWRITE" -eq 1 ]; then
    VLESS_UUID=$(/usr/local/bin/xray uuid || true)
    X25519_JSON=$(/usr/local/bin/xray x25519 -format=json 2>/dev/null || true)
    VLESS_PRIV_KEY=""
    VLESS_PUB_KEY=""

    if [ -n "$X25519_JSON" ]; then
      VLESS_PRIV_KEY=$(printf '%s' "$X25519_JSON" | sed -n 's/.*"privateKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
      VLESS_PUB_KEY=$(printf '%s' "$X25519_JSON" | sed -n 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
      [ -z "$VLESS_PUB_KEY" ] && VLESS_PUB_KEY=$(printf '%s' "$X25519_JSON" | sed -n 's/.*"publicKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    fi

    if [ -z "$VLESS_PRIV_KEY" ] || [ -z "$VLESS_PUB_KEY" ]; then
      X25519_TXT=$(/usr/local/bin/xray x25519 2>/dev/null || true)
      [ -z "$VLESS_PRIV_KEY" ] && VLESS_PRIV_KEY=$(printf '%s\n' "$X25519_TXT" | awk -F':' '/[Pp]rivate ?[Kk]ey/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
      [ -z "$VLESS_PUB_KEY" ] && VLESS_PUB_KEY=$(printf '%s\n' "$X25519_TXT" | awk -F':' '/([Pp]ublic ?[Kk]ey|[Pp]assword)/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
    fi
  fi

  if [ -z "${VLESS_UUID:-}" ] || [ -z "${VLESS_PRIV_KEY:-}" ] || [ -z "${VLESS_PUB_KEY:-}" ]; then
    printf "%b警告: VLESS 密钥生成失败，跳过 VLESS 部署%b\n" "$YELLOW" "$PLAIN"
    INSTALL_VLESS=0
  else
    cat > /etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${OPTIMIZED_SNI}:443",
          "xver": 0,
          "serverNames": [
            "${OPTIMIZED_SNI}"
          ],
          "privateKey": "${VLESS_PRIV_KEY:-}",
          "shortIds": [
            "${VLESS_SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
    chmod 600 /etc/xray/config.json
  fi
fi

cat > "$STATE_FILE" <<EOF
PORT=${PORT}
OPTIMIZED_SNI=${OPTIMIZED_SNI}
HY_PASS=${HY_PASS}
HY_OBFS_PASS=${HY_OBFS_PASS}
VLESS_SHORT_ID=${VLESS_SHORT_ID}
VLESS_UUID=${VLESS_UUID:-}
VLESS_PRIV_KEY=${VLESS_PRIV_KEY:-}
VLESS_PUB_KEY=${VLESS_PUB_KEY:-}
EOF
chmod 600 "$STATE_FILE"

# ===== [5/6] 调优内核 UDP 缓冲区与建立服务 =====
printf "%b[5/6] 配置内核 UDP 缓冲区与服务管理...%b\n" "$YELLOW" "$PLAIN"
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-hy2-buffers.conf <<EOF
net.core.rmem_max = 25000000
net.core.wmem_max = 25000000
EOF
chmod 644 /etc/sysctl.d/99-hy2-buffers.conf
sysctl -p /etc/sysctl.d/99-hy2-buffers.conf >/dev/null 2>&1 || printf "%b提示: 容器受限环境下未能动态调整 sysctl，请确认宿主机 net.core.rmem_max / wmem_max 已调大%b\n" "$YELLOW" "$PLAIN"

trim_log() {
  log_file="$1"
  max_bytes=10485760
  if [ -f "$log_file" ]; then
    size_bytes=$(wc -c < "$log_file" 2>/dev/null || echo 0)
    if [ "$size_bytes" -gt "$max_bytes" ]; then
      tail -c 2097152 "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
    fi
  fi
}

trim_log /var/log/hysteria.log
trim_log /var/log/xray.log

if command -v openrc-run >/dev/null 2>&1 && [ -d /run/openrc ]; then
  cat > /etc/init.d/hysteria <<'EOF'
#!/sbin/openrc-run
name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"

depend() {
  need net
}
EOF
  chmod 755 /etc/init.d/hysteria
  rc-update add hysteria default >/dev/null 2>&1 || true

  if [ "$INSTALL_VLESS" -eq 1 ]; then
    cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
name="xray"
command="/usr/local/bin/xray"
command_args="run -c /etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.log"

depend() {
  need net
}
EOF
    chmod 755 /etc/init.d/xray
    rc-update add xray default >/dev/null 2>&1 || true
  fi

  rc-service hysteria restart
  if [ "$INSTALL_VLESS" -eq 1 ]; then
    rc-service xray restart
  fi
else
  for old_p in "$OLD_HY_PID" "$OLD_XRAY_PID"; do
    if [ -n "$old_p" ] && kill -0 "$old_p" 2>/dev/null; then
      kill "$old_p" 2>/dev/null || true
    fi
  done
  sleep 1

  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml >> /var/log/hysteria.log 2>&1 &
  printf "%s\n" "$!" > "$HY_PID_FILE"

  if [ "$INSTALL_VLESS" -eq 1 ]; then
    nohup /usr/local/bin/xray run -c /etc/xray/config.json >> /var/log/xray.log 2>&1 &
    printf "%s\n" "$!" > "$XRAY_PID_FILE"
  fi
fi

# ===== [6/6] 启动验证与输出信息 =====
printf "%b[6/6] 验证服务监听与运行状态...%b\n" "$YELLOW" "$PLAIN"
sleep 2

udp_ok=0
tcp_ok=0
if ss -H -lnu "sport = :$PORT" 2>/dev/null | grep -q .; then
  udp_ok=1
fi
if ss -H -lnt "sport = :$PORT" 2>/dev/null | grep -q .; then
  tcp_ok=1
fi

if [ "$udp_ok" -ne 1 ]; then
  printf "%b错误: Hysteria 2 未在 UDP :%s 正常监听，最近日志如下:%b\n" "$RED" "$PORT" "$PLAIN" >&2
  tail -n 20 /var/log/hysteria.log 2>/dev/null >&2 || true
  exit 1
fi

if [ "$INSTALL_VLESS" -eq 1 ] && [ "$tcp_ok" -ne 1 ]; then
  printf "%b错误: Xray VLESS 未在 TCP :%s 正常监听，最近日志如下:%b\n" "$RED" "$PORT" "$PLAIN" >&2
  tail -n 20 /var/log/xray.log 2>/dev/null >&2 || true
  exit 1
fi

SERVER_IP="$CUSTOM_IP"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -fsSL4 --max-time 5 https://api.ipify.org 2>/dev/null || curl -fsSL6 --max-time 5 https://api64.ipify.org 2>/dev/null || true)
fi
if [ -z "$SERVER_IP" ]; then
  printf "%b错误: 无法自动获取公网 IP，请使用 -i 参数手动指定%b\n" "$RED" "$PLAIN" >&2
  exit 1
fi

case "$SERVER_IP" in
  *:*) HOST_ADDR="[${SERVER_IP}]" ;;
  *)   HOST_ADDR="${SERVER_IP}" ;;
esac

printf "\n%b================================================================%b\n" "$GREEN" "$PLAIN"
printf "%b同端口双协议 (VLESS-Reality + Hy2 Gecko) 部署并验证成功%b\n" "$GREEN" "$PLAIN"
printf "%b================================================================%b\n" "$GREEN" "$PLAIN"
printf " 服务器地址 (Address) : %b%s%b\n" "$CYAN" "$SERVER_IP" "$PLAIN"
printf " 共用监听端口 (Port)  : %b%s (TCP: VLESS / UDP: Hy2)%b\n" "$CYAN" "$PORT" "$PLAIN"
printf " 优选 SNI 域名        : %b%s%b\n" "$CYAN" "$OPTIMIZED_SNI" "$PLAIN"
printf "----------------------------------------------------------------\n"
printf " [1] Hysteria 2 配置信息 (Gecko)\n"
printf "   - 认证密码 : %b%s%b\n" "$CYAN" "$HY_PASS" "$PLAIN"
printf "   - 混淆类型 : %bgecko%b\n" "$CYAN" "$PLAIN"
printf "   - 混淆密码 : %b%s%b\n" "$CYAN" "$HY_OBFS_PASS" "$PLAIN"
if [ "$INSTALL_VLESS" -eq 1 ]; then
  printf "----------------------------------------------------------------\n"
  printf " [2] VLESS-Reality 配置信息\n"
  printf "   - UUID       : %b%s%b\n" "$CYAN" "${VLESS_UUID:-}" "$PLAIN"
  printf "   - 流控 (Flow): %bxtls-rprx-vision%b\n" "$CYAN" "$PLAIN"
  printf "   - PublicKey  : %b%s%b\n" "$CYAN" "${VLESS_PUB_KEY:-}" "$PLAIN"
  printf "   - ShortId    : %b%s%b\n" "$CYAN" "${VLESS_SHORT_ID:-}" "$PLAIN"
fi
printf "----------------------------------------------------------------\n"
printf "%b[Hysteria 2 直连链接]:%b\n" "$YELLOW" "$PLAIN"
printf "%bhy2://%s@%s:%s?insecure=1&sni=%s&obfs=gecko&obfs-password=%s#Hy2-Gecko-SharedPort%b\n" \
  "$CYAN" "$HY_PASS" "$HOST_ADDR" "$PORT" "$OPTIMIZED_SNI" "$HY_OBFS_PASS" "$PLAIN"
if [ "$INSTALL_VLESS" -eq 1 ]; then
  printf "\n%b[VLESS-Reality 直连链接]:%b\n" "$YELLOW" "$PLAIN"
  printf "%bvless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#VLESS-Reality-SharedPort%b\n" \
    "$CYAN" "${VLESS_UUID:-}" "$HOST_ADDR" "$PORT" "$OPTIMIZED_SNI" "${VLESS_PUB_KEY:-}" "${VLESS_SHORT_ID:-}" "$PLAIN"
fi
printf "----------------------------------------------------------------\n"
printf "%b安全与运维提醒:%b\n" "$YELLOW" "$PLAIN"
printf " 1. Hy2 链接包含 insecure=1 (跳过自签证书校验)，存在中间人风险，仅作便利使用。\n"
printf " 2. 终端已明文输出密钥与链接，请妥善保管并注意清理命令历史或 CI 日志。\n"
printf " 3. 若外部无法连通，请检查主机防火墙及云厂商安全组是否放行 TCP/%s 与 UDP/%s。\n" "$PORT" "$PORT"
printf "%b================================================================%b\n" "$GREEN" "$PLAIN"
EOF
