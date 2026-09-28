#!/bin/bash
# Hysteria 2 一键安装脚本 for Alpine Linux (OpenRC)
# 已清除默认端口 - 必须指定端口

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 默认值
DEFAULT_PASSWORD=""

# 解析参数
while getopts "p:w:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    h) 
      echo "用法: $0 [-p 端口] [-w 密码]"
      echo "  -p  自定义端口 (1-65535), 必填"
      echo "  -w  自定义密码, 默认随机生成"
      echo "  环境变量也支持: PORT=xxx PASSWORD=xxx $0"
      exit 0
      ;;
    *) ;;
  esac
done

# 支持环境变量
CUSTOM_PORT=${CUSTOM_PORT:-${PORT:-}}
CUSTOM_PASSWORD=${CUSTOM_PASSWORD:-${PASSWORD:-}}

# 检查 root
if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}错误: 请使用 root 用户运行${PLAIN}"
  exit 1
fi

# 检查 Alpine
if [ ! -f /etc/alpine-release ]; then
  echo -e "${YELLOW}警告: 未检测到 Alpine 系统，但将继续尝试...${PLAIN}"
fi

# 获取架构
get_arch() {
  ARCH=$(uname -m)
  case $ARCH in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *) echo "amd64" ;;
  esac
}

# 生成随机密码
gen_password() {
  tr -dc 'A-Za-z0-9!@#$%^&*()_+' < /dev/urandom | head -c 16
  echo
}

# 端口处理 - 已无默认值，强制输入
validate_port() {
  case $1 in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -ge 1 ] && [ "$1" -le 65535 ] ;;
  esac
}

if [ -z "$CUSTOM_PORT" ]; then
  while true; do
    read -p "请输入 Hysteria 2 端口 (1-65535, 必填): " input_port
    if validate_port "$input_port"; then
      HY_PORT=$input_port
      break
    else
      echo -e "${RED}无效端口，请输入 1-65535${PLAIN}"
    fi
  done
else
  if ! validate_port "$CUSTOM_PORT"; then
    echo -e "${RED}错误: 端口 $CUSTOM_PORT 无效，必须是 1-65535${PLAIN}"
    exit 1
  fi
  HY_PORT=$CUSTOM_PORT
fi

# 密码处理
if [ -z "$CUSTOM_PASSWORD" ]; then
  read -p "请输入 Hysteria 2 密码 [回车随机生成]: " input_pass
  if [ -z "$input_pass" ]; then
    HY_PASS=$(
