#!/bin/bash
# Hysteria 2 一键安装脚本 V3.1 - 1Gbps 专用版
# 升级点: 默认自动生成20个离散随机端口，抗封锁 x10，不再用连续段
# 用法:
#   ./hysteria2-alpine-install-v3-1g.sh                    # 自动 20个随机端口
#   ./hysteria2-alpine-install-v3-1g.sh -p 56764 -s www.bing.com
#   ./hysteria2-alpine-install-v3-1g.sh -r 20000-20020    # 兼容旧的连续段
#   ./hysteria2-alpine-install-v3-1g.sh -r 13231,24567,31889  # 自定义离散
#   ./hysteria2-alpine-install-v3-1g.sh -r auto           # 强制随机20个

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

DEFAULT_PORT=56764
DEFAULT_SNI="www.bing.com"
DEFAULT_HOP_COUNT=20

while getopts "p:w:o:s:r:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    o) CUSTOM_OBFS=$OPTARG ;;
    s) CUSTOM_SNI=$OPTARG ;;
    r) CUSTOM_RANGE=$OPTARG ;;
    h) echo "用法: $0 [-p 主端口] [-w 认证密码] [-o 混淆密码] [-s SNI] [-r auto|20000-20010|13231,24567]"; exit 0 ;;
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
  openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 16
}

# 生成 N 个离散随机端口，10000-60000，避免重复和主端口
gen_random_ports() {
  local count=$1
  local main_port=$2
  local min=10000
  local max=60000
  local ports=""
  local tries=0
  local i=0
  while [ $i -lt $count ]; do
    tries=$((tries+1))
    if [ $tries -gt 1000 ]; then break; fi # 防止死循环
    if command -v shuf >/dev/null 2>&1; then
      p=$(shuf -i ${min}-${max} -n 1)
    else
      # 纯bash随机
      p=$(( RANDOM % (max - min + 1) + min ))
      # 再叠加一次 urandom 提高随机性
      p2=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      p=$(( (p + p2) % (max - min + 1) + min ))
    fi
    if [ "$p" -eq "$main_port" ]; then continue; fi
    if [ "$p" -lt "$min" ] || [ "$p" -gt "$max" ]; then continue; fi
    # 去重
    echo ",$ports," | grep -q ",$p," && continue
    if [ -z "$ports" ]; then
      ports="$p"
    else
      ports="$ports,$p"
    fi
    i=$((i+1))
  done
  echo "$ports"
}

if [ -z "$CUSTOM_PORT" ]; then
  read -p "请输入主端口 [默认 $DEFAULT_PORT]: " input_port
  HY_PORT=${input_port:-$DEFAULT_PORT}
else
  HY_PORT=$CUSTOM_PORT
fi

if [ -z "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$(gen_password)
  echo -e "${YELLOW}认证密码随机: $HY_PASS${PLAIN}"
else
  HY_PASS=$CUSTOM_PASSWORD
fi

if [ -z "$CUSTOM_OBFS" ]; then
  HY_OBFS=$(gen_password)
  echo -e "${YELLOW}混淆密码随机: $HY_OBFS${PLAIN}"
else
  HY_OBFS=$CUSTOM_OBFS
fi

HY_SNI=$CUSTOM_SNI

# --- 核心升级: 端口处理逻辑 ---
HY_RANGE_TYPE=""
HY_HOPS_STR=""
HY_DISCRETE_LIST=""

if [ -z "$CUSTOM_RANGE" ] || [ "$CUSTOM_RANGE" = "auto" ] || [ "$CUSTOM_RANGE" = "random" ]; then
  echo -e "${YELLOW}未指定 -r，自动生成 ${DEFAULT_HOP_COUNT} 个离散随机端口...${PLAIN}"
  HY_DISCRETE_LIST=$(gen_random_ports $DEFAULT_HOP_COUNT $HY_PORT)
  HY_HOPS_STR=$HY_DISCRETE_LIST
  HY_RANGE_TYPE="discrete"
elif echo "$CUSTOM_RANGE" | grep -q ","; then
  # 用户给了离散列表
  HY_DISCRETE_LIST=$CUSTOM_RANGE
  HY_HOPS_STR=$CUSTOM_RANGE
  HY_RANGE_TYPE="discrete"
  echo -e "${BLUE}使用自定义离散端口: $HY_HOPS_STR${PLAIN}"
else
  # 认为是连续段 20000-20010
  HY_HOPS_STR=$CUSTOM_RANGE
  HY_RANGE_TYPE="range"
  echo -e "${BLUE}使用自定义连续段: $HY_HOPS_STR${PLAIN}"
fi

echo -e "${GREEN}=== Hysteria 2 V3.1 1Gbps版 ===${PLAIN}"
echo -e "主端口: $HY_PORT  SNI: $HY_SNI"
echo -e "跳跃端口 (${HY_RANGE_TYPE}): $HY_HOPS_STR"

echo -e "${YELLOW}[1/6] 安装依赖...${PLAIN}"
apk update
apk add --no-cache bash curl wget openssl tar iproute2 iptables file ca-certificates

mkdir -p /usr/local/bin /etc/ssl/private /etc/hysteria /var/log

echo -e "${YELLOW}[2/6] 下载 Hysteria 2 (官方源 + 校验)...${PLAIN}"
ARCH_TYPE=$(get_arch)
BIN_NAME="hysteria-linux-${ARCH_TYPE}"
DEST="/usr/local/bin/hysteria"
OFFICIAL_URL="https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
CHECKSUM_URL="https://github.com/apernet/hysteria/releases/latest/download/checksums.txt"
rm -f /tmp/hy.download /tmp/checksums.txt
download_success=0
for i in 1 2 3; do
  echo -e "  尝试官方源第 $i 次..."
  if curl -fL --connect-timeout 15 --max-time 120 -o /tmp/hy.download "$OFFICIAL_URL"; then
    if head -c 100 /tmp/hy.download | grep -qi "<!DOCTYPE\|<html"; then sleep 2; continue; fi
    if ! head -c 4 /tmp/hy.download | grep -q $'\x7fELF'; then sleep 2; continue; fi
    SIZE=$(wc -c < /tmp/hy.download)
    if [ "$SIZE" -lt 3000000 ]; then sleep 2; continue; fi
    if curl -fL --connect-timeout 10 --max-time 30 -o /tmp/checksums.txt "$CHECKSUM_URL" 2>/dev/null; then
        EXPECTED_SHA=$(grep "$BIN_NAME" /tmp/checksums.txt | awk '{print $1}')
        if [ -n "$EXPECTED_SHA" ]; then
            ACTUAL_SHA=$(sha256sum /tmp/hy.download | awk '{print $1}')
            if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then echo -e "${RED}SHA256校验失败，重试...${PLAIN}"; continue; fi
        fi
    fi
    mv /tmp/hy.download "$DEST"; chmod +x "$DEST"; download_success=1; echo -e "${GREEN}下载成功 $SIZE bytes${PLAIN}"; break
  fi
  sleep 3
done
if [ "$download_success" -ne 1 ]; then echo -e "${RED}下载失败，请检查能否直连GitHub${PLAIN}"; exit 1; fi
"$DEST" version

echo -e "${YELLOW}[3/6] 生成证书 CN=${HY_SNI}...${PLAIN}"
openssl ecparam -genkey -name prime256v1 -noout -out /etc/ssl/private/hysteria.key
openssl req -new -x509 -nodes -key /etc/ssl/private/hysteria.key -out /etc/ssl/private/hysteria.crt -days 3650 -subj "/CN=${HY_SNI}/O=Private"
chmod 600 /etc/ssl/private/hysteria.key; chmod 644 /etc/ssl/private/hysteria.crt

echo -e "${YELLOW}[4/6] 生成配置 (Salamander混淆)...${PLAIN}"
cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}
tls:
  cert: /etc/ssl/private/hysteria.crt
  key: /etc/ssl/private/hysteria.key
obfs:
  type: salamander
  salamander:
    password: "${HY_OBFS}"
auth:
  type: password
  password: "${HY_PASS}"
ignoreClientBandwidth: true
disableUDP: false
masquerade:
  type: proxy
  proxy:
    url: https://${HY_SNI}
    rewriteHost: true
log:
  level: warn
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF
chmod 600 /etc/hysteria/config.yaml

echo -e "${YELLOW}[5/6] 创建服务 + 防火墙...${PLAIN}"
cat > /etc/init.d/hysteria <<'SERVICE_EOF'
#!/sbin/openrc-run
name="Hysteria 2 Service"
description="Hysteria 2 Proxy Server V3.1"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
depend() { need net; after firewall; }
start_pre() { checkpath --directory --mode 0755 /run; checkpath --file --mode 0644 /var/log/hysteria.log; }
SERVICE_EOF
chmod +x /etc/init.d/hysteria; rc-update add hysteria default

# 防火墙
if command -v iptables >/dev/null 2>&1; then
    echo -e "  放行主端口 UDP ${HY_PORT}"
    iptables -C INPUT -p udp --dport ${HY_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${HY_PORT} -j ACCEPT
    if [ "$HY_RANGE_TYPE" = "discrete" ]; then
        echo -e "  配置离散跳跃端口 DNAT -> ${HY_PORT}"
        # 清理旧的 discrete 规则 (尽力)
        # 添加新规则
        IFS=',' read -ra PORT_ARR <<< "$HY_DISCRETE_LIST"
        for p in "${PORT_ARR[@]}"; do
            p=$(echo $p | tr -d ' ')
            [ -z "$p" ] && continue
            iptables -C INPUT -p udp --dport $p -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport $p -j ACCEPT
            iptables -t nat -C PREROUTING -p udp --dport $p -j DNAT --to-destination :${HY_PORT} 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport $p -j DNAT --to-destination :${HY_PORT}
        done
    else
        START=$(echo $HY_HOPS_STR | cut -d'-' -f1); END=$(echo $HY_HOPS_STR | cut -d'-' -f2)
        if [ -n "$START" ] && [ -n "$END" ]; then
            echo -e "  配置连续段 $START:$END -> $HY_PORT"
            iptables -t nat -C PREROUTING -p udp --dport ${START}:${END} -j DNAT --to-destination :${HY_PORT} 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport ${START}:${END} -j DNAT --to-destination :${HY_PORT}
            iptables -C INPUT -p udp --dport ${START}:${END} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${START}:${END} -j ACCEPT
        fi
    fi
fi

echo -e "${YELLOW}[6/6] 启动...${PLAIN}"
rc-service hysteria restart || rc-service hysteria start; sleep 2
rc-service hysteria status || { cat /var/log/hysteria.log; exit 1; }

SERVER_IP=$(curl -4 -s --max-time 5 https://ifconfig.me || curl -4 -s --max-time 5 https://ipinfo.io/ip || echo "YOUR_SERVER_IP")

echo ""
echo -e "${GREEN}========== V3.1 1Gbps版安装完成 ==========${PLAIN}"
echo -e "主端口: ${GREEN}${HY_PORT}${PLAIN}"
echo -e "跳跃: ${GREEN}${HY_HOPS_STR}${PLAIN} (${HY_RANGE_TYPE}, 共 $(echo $HY_HOPS_STR | tr ',' '\n' | wc -l | tr -d ' ') 个)"
echo -e "认证: ${GREEN}${HY_PASS}${PLAIN}"
echo -e "混淆: ${GREEN}${HY_OBFS}${PLAIN}"
echo -e "SNI: ${GREEN}${HY_SNI}${PLAIN}"
echo ""
echo -e "${BLUE}--- 客户端 YAML ---${PLAIN}"
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
  down: 1000 mbps
hopInterval: 30s
# 重要: 跳跃端口
hops: ${HY_HOPS_STR}
CLIENT_YAML

echo ""
echo -e "${BLUE}--- URI (带mport) ---${PLAIN}"
# mport 参数 Hysteria2 官方支持离散列表
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=${HY_SNI}&obfs=salamander&obfs-password=${HY_OBFS}&insecure=1&mport=${HY_HOPS_STR}#Alpine-Hy2-V3.1-1G-${SERVER_IP}${PLAIN}"
echo ""
echo -e "${BLUE}--- Clash.Meta 配置片段 ---${PLAIN}"
cat <<CLASH
- name: Hy2-1G
  type: hysteria2
  server: ${SERVER_IP}
  port: ${HY_PORT}
  ports: ${HY_HOPS_STR}
  hop-interval: 30
  password: ${HY_PASS}
  obfs: salamander
  obfs-password: ${HY_OBFS}
  sni: ${HY_SNI}
  skip-cert-verify: true
  up: 100
  down: 1000
CLASH
echo ""
echo -e "${YELLOW}提示: 已自动生成20个离散随机端口，防火墙已放行。云服务商安全组也请放行 UDP ${HY_PORT} 和 ${HY_HOPS_STR}${PLAIN}"
echo -e "卸载: rc-service hysteria stop; rc-update del hysteria; rm -rf /etc/hysteria /etc/init.d/hysteria /usr/local/bin/hysteria /etc/ssl/private/hysteria.*"
echo -e "清理iptables: iptables -t nat -F; iptables -F (注意这会清所有规则，谨慎使用，或手动删除上述端口)"
