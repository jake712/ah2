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
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_valid_ip() {
  ip="$1"
  if printf '%s' "$ip" \vert{} grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    IFS=. read -r o1 o2 o3 o4 <<EOF
$ip
EOF
    for o in "$o1" "$o2" "$o3" "$o4"; do
      [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
    done
    return 0
  fi
  if printf '%s' "$ip" \vert{} grep -Eq '^[0-9A-Fa-f:]+$'; then
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
  "$bin_path" version >/dev/null 2>&1 \vert{}\vert{} "$bin_path" -v >/dev/null 2>&1 || return 1
  return 0
}

verify_sha256_if_available() {
  file_path="$1"
  sums_url="$2"
  asset_name="$3" tmp_sums="/tmp/release_sums.$$"
  rm -f "$tmp_sums"
  if curl -fsSL --max-time 15 -o "$tmp_sums" "$sums_url" 2>/dev/null && [ -s "$tmp_sums" ]; then
    expected=$(awk -v target="$asset_name" '$2 ~ ("(^\vert{}/)" target "$") {print $1; exit}' "$tmp_sums")
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
  seed=$(($(date +\%s) +$$))
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
  occ_pids=$(ss -H -lntup "sport = :$PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).
