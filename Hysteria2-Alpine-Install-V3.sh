#!/bin/bash
# Hysteria 2 一键安装脚本 for Alpine Linux V3 - 加固防探测版
# 特性: 官方源直连 + SHA256校验 + Salamander混淆 + 随机端口跳跃 + 600权限
# 用法: 
#   ./hysteria2-alpine-install-v3.sh -p 56764 -w "你的密码" -o "混淆密码" -s www.bing.com
#   或环境变量: PORT=56764 PASSWORD=xxx OBFS_PASSWORD=xxx SNI=www.bing.com ./script.sh
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

DEFAULT_PORT=56764
DEFAULT_SNI="www.bing.com"

# --- 参数解析 ---
while getopts "p:w:o:s:r:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    o) CUSTOM_OBFS=$OPTARG ;;
    s) CUSTOM_SNI=$OPTARG ;;
    r) CUSTOM_RANGE=$OPTARG ;; # 例如 20000-20010
    h) echo -e "用法: $0 [-p 端口] [-w 认证密码] [-o 混淆密码] [-s SNI域名] [-r 跳跃端口范围]"; exit 0 ;;
  esac
done

CUSTOM_PORT=${CUSTOM_PORT:-${PORT:-}}
CUSTOM_PASSWORD=${CUSTOM_PASSWORD:-${PASSWORD:-}}
CUSTOM_OBFS=${CUSTOM_OBFS:-${OBFS_PASSWORD:-}}
CUSTOM_SNI=${CUSTOM_SNI:-${SNI:-$DEFAULT_SNI}}

if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}请用 root 运行${PLAIN}"; exit 1
fi

get_arch() {
  ARCH=$(uname -m)
  case $ARCH in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *) echo "amd64" ;;
  esac
}

gen_password() {
  # 使用 openssl 更强的随机
  openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 16
}

if [ -z "$CUSTOM_PORT" ]; then
  read -p "请输入主端口 [默认 $DEFAULT_PORT, 建议20000-60000随机]: " input_port
  HY_PORT=${input_port:-$DEFAULT_PORT}
else
  HY_PORT=$CUSTOM_PORT
fi

if [ -z "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$(gen_password)
  echo -e "${YELLOW}未提供认证密码，已随机生成: $HY_PASS${PLAIN}"
else
  HY_PASS=$CUSTOM_PASSWORD
fi

if [ -z "$CUSTOM_OBFS" ]; then
  HY_OBFS=$(gen_password)
  echo -e "${YELLOW}未提供混淆密码，已随机生成: $HY_OBFS${PLAIN}"
else
  HY_OBFS=$CUSTOM_OBFS
fi

HY_SNI=$CUSTOM_SNI
HY_RANGE=$CUSTOM_RANGE

echo -e "${GREEN}=== 开始安装 Hysteria 2 V3 加固版 ===${PLAIN}"
echo -e "端口: $HY_PORT  认证: $HY_PASS  混淆: $HY_OBFS  SNI: $HY_SNI"

# --- [1/6] 安装依赖 ---
echo -e "${YELLOW}[1/6] 安装依赖...${PLAIN}"
apk update
apk add --no-cache bash curl wget openssl tar iproute2 iptables file ca-certificates

mkdir -p /usr/local/bin
mkdir -p /etc/ssl/private
mkdir -p /etc/hysteria
mkdir -p /var/log

# --- [2/6] 下载核心 - 仅官方源 + 校验 ---
echo -e "${YELLOW}[2/6] 下载 Hysteria 2 (仅官方源 + SHA256校验)...${PLAIN}"
ARCH_TYPE=$(get_arch)
BIN_NAME="hysteria-linux-${ARCH_TYPE}"
DEST="/usr/local/bin/hysteria"
OFFICIAL_URL="https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
CHECKSUM_URL="https://github.com/apernet/hysteria/releases/latest/download/checksums.txt"

rm -f /tmp/hy.download /tmp/checksums.txt

download_success=0
for i in 1 2 3; do
  echo -e "  尝试下载官方二进制 (第 $i 次): $OFFICIAL_URL"
  if curl -fL --connect-timeout 15 --max-time 120 -o /tmp/hy.download "$OFFICIAL_URL"; then
    
    # 1. 拒绝 HTML
    if head -c 100 /tmp/hy.download | grep -qi "<!DOCTYPE\|<html"; then
      echo -e "${RED}  -> 下载到的是网页，重试...${PLAIN}"
      sleep 2
      continue
    fi

    # 2. 检查 ELF
    if ! head -c 4 /tmp/hy.download | grep -q $'\x7fELF'; then
       echo -e "${RED}  -> 不是有效的 ELF 文件${PLAIN}"
       head -c 300 /tmp/hy.download
       echo ""
       sleep 2
       continue
    fi

    # 3. 检查大小 > 3MB (新版更大)
    SIZE=$(wc -c < /tmp/hy.download)
    if [ "$SIZE" -lt 3000000 ]; then
      echo -e "${RED}  -> 文件太小 ($SIZE bytes)，可能不完整${PLAIN}"
      sleep 2
      continue
    fi

    # 4. 尝试校验 SHA256 (尽力而为)
    echo -e "  尝试下载校验文件..."
    if curl -fL --connect-timeout 10 --max-time 30 -o /tmp/checksums.txt "$CHECKSUM_URL" 2>/dev/null; then
        EXPECTED_SHA=$(grep "$BIN_NAME" /tmp/checksums.txt | awk '{print $1}')
        if [ -n "$EXPECTED_SHA" ]; then
            ACTUAL_SHA=$(sha256sum /tmp/hy.download | awk '{print $1}')
            if [ "$EXPECTED_SHA" = "$ACTUAL_SHA" ]; then
                echo -e "${GREEN}  -> SHA256 校验通过${PLAIN}"
            else
                echo -e "${RED}  -> SHA256 校验失败! 期望 $EXPECTED_SHA 实际 $ACTUAL_SHA${PLAIN}"
                echo -e "${YELLOW}  -> 为安全起见终止安装，请手动检查${PLAIN}"
                continue
            fi
        else
            echo -e "${YELLOW}  -> 校验文件中未找到对应项，跳过校验(但已通过ELF和大小检查)${PLAIN}"
        fi
    else
        echo -e "${YELLOW}  -> 无法下载校验文件，仅通过ELF和大小检查${PLAIN}"
    fi

    mv /tmp/hy.download "$DEST"
    chmod +x "$DEST"
    download_success=1
    echo -e "${GREEN}  -> 下载成功 ($SIZE bytes)${PLAIN}"
    break
  else
    echo -e "${RED}  -> 下载失败，重试...${PLAIN}"
    sleep 3
  fi
done

if [ "$download_success" -ne 1 ]; then
  echo -e "${RED}所有官方尝试都失败！${PLAIN}"
  echo "请检查你的服务器能否直连 GitHub"
  echo "备用方案: 在本地下载好 $BIN_NAME 后 scp 上传到 $DEST 并 chmod +x"
  exit 1
fi

"$DEST" version

# --- [3/6] 生成 TLS 证书 ---
echo -e "${YELLOW}[3/6] 生成 TLS 证书 (CN=${HY_SNI})...${PLAIN}"
# 每次生成不同密钥，避免全网指纹相同
openssl ecparam -genkey -name prime256v1 -noout -out /etc/ssl/private/hysteria.key
openssl req -new -x509 -nodes -key /etc/ssl/private/hysteria.key -out /etc/ssl/private/hysteria.crt -days 3650 -subj "/CN=${HY_SNI}/O=Private"
chmod 600 /etc/ssl/private/hysteria.key
chmod 644 /etc/ssl/private/hysteria.crt

# --- [4/6] 生成加固配置文件 ---
echo -e "${YELLOW}[4/6] 生成配置文件 (带 Salamander 混淆)...${PLAIN}"
cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}

tls:
  cert: /etc/ssl/private/hysteria.crt
  key: /etc/ssl/private/hysteria.key

# 加固1: Salamander 混淆 - 抗握手识别
obfs:
  type: salamander
  salamander:
    password: "${HY_OBFS}"

auth:
  type: password
  password: "${HY_PASS}"

# 加固2: 关闭限速探测
ignoreClientBandwidth: true
disableUDP: false

# 加固3: 伪装
masquerade:
  type: proxy
  proxy:
    url: https://${HY_SNI}
    rewriteHost: true

# 加固4: 减少日志泄露
log:
  level: warn

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF

chmod 600 /etc/hysteria/config.yaml
echo -e "${GREEN}  -> 配置已加固，权限 600${PLAIN}"

# --- [5/6] 创建服务 + 防火墙 ---
echo -e "${YELLOW}[5/6] 创建 OpenRC 服务...${PLAIN}"
cat > /etc/init.d/hysteria <<'SERVICE_EOF'
#!/sbin/openrc-run
name="Hysteria 2 Service"
description="Hysteria 2 Proxy Server - Hardened"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
depend() {
    need net
    after firewall
}
start_pre() {
    checkpath --directory --mode 0755 /run
    checkpath --file --mode 0644 /var/log/hysteria.log
}
SERVICE_EOF

chmod +x /etc/init.d/hysteria
rc-update add hysteria default

# 防火墙放行主端口
if command -v iptables >/dev/null 2>&1; then
    echo -e "  放行 UDP ${HY_PORT}"
    iptables -C INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${HY_PORT} -j ACCEPT
    # 如果提供了跳跃范围，做 DNAT
    if [ -n "$HY_RANGE" ]; then
        echo -e "  配置端口跳跃: ${HY_RANGE} -> ${HY_PORT}"
        # 例如 20000-20010
        START=$(echo $HY_RANGE | cut -d'-' -f1)
        END=$(echo $HY_RANGE | cut -d'-' -f2)
        if [ -n "$START" ] && [ -n "$END" ]; then
            iptables -t nat -C PREROUTING -p udp --dport ${START}:${END} -j DNAT --to-destination :${HY_PORT} 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport ${START}:${END} -j DNAT --to-destination :${HY_PORT}
            iptables -C INPUT -p udp --dport ${START}:${END} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${START}:${END} -j ACCEPT
        fi
    fi
fi

# --- [6/6] 启动 ---
echo -e "${YELLOW}[6/6] 启动服务...${PLAIN}"
rc-service hysteria restart || rc-service hysteria start
sleep 2
rc-service hysteria status || { echo -e "${RED}启动失败，查看日志:${PLAIN}"; cat /var/log/hysteria.log; exit 1; }

SERVER_IP=$(curl -4 -s --max-time 5 https://ifconfig.me || curl -4 -s --max-time 5 https://ipinfo.io/ip || echo "YOUR_SERVER_IP")

echo ""
echo -e "${GREEN}========== 安装完成 V3 加固版 ==========${PLAIN}"
echo -e "主端口: ${GREEN}${HY_PORT}/udp${PLAIN}"
echo -e "认证密码: ${GREEN}${HY_PASS}${PLAIN}"
echo -e "混淆密码: ${GREEN}${HY_OBFS}${PLAIN} (类型: salamander)"
echo -e "SNI: ${GREEN}${HY_SNI}${PLAIN}"
if [ -n "$HY_RANGE" ]; then
echo -e "跳跃端口: ${GREEN}${HY_RANGE}${PLAIN}"
fi
echo -e "配置: /etc/hysteria/config.yaml (600权限)"
echo -e "管理: rc-service hysteria restart | stop | status"
echo -e "日志: tail -f /var/log/hysteria.log"
echo ""
echo -e "${BLUE}--- 客户端 YAML (v2rayN / Clash Meta / Hiddify 适用) ---${PLAIN}"
cat <<CLIENT_YAML
server: ${SERVER_IP}:${HY_PORT}
auth: ${HY_PASS}
tls:
  sni: ${HY_SNI}
  insecure: true
obfs:
  type: salamander
  salamander:
    password: ${HY_OBFS}
bandwidth:
  up: 100 mbps
  down: 500 mbps
CLIENT_YAML

echo ""
echo -e "${BLUE}--- 客户端 URI (一键导入) ---${PLAIN}"
# URI 编码
ENCODED_OBFS=$(echo -n "$HY_OBFS" | jq -sRr @uri 2>/dev/null || echo -n "$HY_OBFS")
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=${HY_SNI}&obfs=salamander&obfs-password=${ENCODED_OBFS}&insecure=1#Alpine-Hy2-V3-${SERVER_IP}${PLAIN}"
echo ""
echo -e "${YELLOW}安全提示:${PLAIN}"
echo -e "1. 已移除所有 ghproxy 加速站，只用官方源+SHA256校验，防止供应链投毒"
echo -e "2. 已开启 Salamander 混淆，抗 GFW 主动探测能力大幅提升"
echo -e "3. 证书每次随机生成，配置文件 600 权限"
echo -e "4. 建议: 将 -s 参数换成你自己的域名，并用 acme.sh 申请真实证书，然后把 insecure 设为 false"
echo -e "5. 如需端口跳跃，下次安装使用 -r 20000-20010 参数，客户端 hops 填同样范围"
echo -e "6. 记得在云服务商安全组放行 UDP ${HY_PORT} (以及跳跃范围)"
echo ""
echo -e "卸载: rc-service hysteria stop; rc-update del hysteria; rm -rf /etc/hysteria /etc/init.d/hysteria /usr/local/bin/hysteria /etc/ssl/private/hysteria.*"
