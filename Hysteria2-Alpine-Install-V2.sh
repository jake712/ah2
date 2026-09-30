#!/bin/sh
# Hysteria 2 Alpine V3.5 - NAT兼容智能IP版
# 修复: V3.4 在 NAT/LXC/容器/DNAT 下无法获取公网IP的问题
# 作者: jake712 原版 + fix

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

while getopts "p:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 端口] [-w 密码] [-i 公网IP]"; exit 0 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

echo -e "${GREEN}=== Hysteria2 Alpine V3.5 NAT兼容版 ===${PLAIN}"

# ===== [1/6] 基础依赖 =====
echo -e "${YELLOW}[1/6] 检查依赖...${PLAIN}"
# Alpine 修复 resolv.conf，不要直接覆盖导致 DNS 挂掉
if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
  echo -e "${YELLOW}修复 DNS...${PLAIN}"
  cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
else
  echo -e "DNS 已存在，跳过覆盖: $(cat /etc/resolv.conf | head -n1)"
fi

apk update >/dev/null 2>&1 || true
apk add --no-cache curl wget ca-certificates openssl bind-tools iproute2 iproute2-ss openrc >/dev/null 2>&1 || \
apk add --no-cache curl wget ca-certificates openssl bind-tools iproute2 openrc >/dev/null 2>&1 || true
update-ca-certificates 2>/dev/null || true

# ===== [2/6] 参数和路径 =====
echo -e "${YELLOW}[2/6] 初始化参数...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-26169}
if [ -n "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$CUSTOM_PASSWORD
else
  if command -v openssl >/dev/null 2>&1; then
    HY_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
  else
    HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
  fi
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  armv7l|arm) HY_ARCH="arm" ;;
  *) HY_ARCH="amd64"; echo -e "${YELLOW}未知架构 $ARCH，默认使用 amd64${PLAIN}" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log
chmod 700 /etc/hysteria

# ===== [3/6] 下载 Hysteria2 =====
echo -e "${YELLOW}[3/6] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
# 尝试3次下载
for i in 1 2 3; do
  echo "尝试下载 $HY_URL (第 $i 次)"
  if curl -fsSL --max-time 30 -o /tmp/hysteria "$HY_URL"; then
    break
  fi
  wget -q --timeout=30 -O /tmp/hysteria "$HY_URL" && break
  sleep 2
done

if [ ! -s /tmp/hysteria ] || head -c 200 /tmp/hysteria | grep -qi "<html"; then
  echo -e "${RED}下载失败，请检查网络或手动下载${PLAIN}"
  echo -e "手动命令: wget -O /usr/local/bin/hysteria $HY_URL"
  exit 1
fi

mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria
echo -e "${GREEN}版本: $(/usr/local/bin/hysteria version 2>&1 | head -n1)${PLAIN}"

# ===== [4/6] 生成证书和配置 =====
echo -e "${YELLOW}[4/6] 生成配置...${PLAIN}"
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  echo -e "生成自签名证书..."
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout /etc/hysteria/key.key -out /etc/hysteria/cert.crt \
    -subj "/CN=bing.com" -days 3650 2>/dev/null || \
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout /etc/hysteria/key.key -out /etc/hysteria/cert.crt \
    -subj "/CN=bing.com" -days 3650
fi

cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}

auth:
  type: password
  password: ${HY_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
EOF

cat /etc/hysteria/config.yaml

# ===== [5/6] OpenRC 服务 =====
echo -e "${YELLOW}[5/6] 配置服务...${PLAIN}"
cat > /etc/init.d/hysteria <<'EOS'
#!/sbin/openrc-run
name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath --directory --mode 0755 /run/hysteria
  checkpath --directory --mode 0755 /etc/hysteria
}
EOS

chmod +x /etc/init.d/hysteria
rc-update add hysteria default >/dev/null 2>&1 || true
rc-service hysteria restart || rc-service hysteria start
sleep 2
rc-service hysteria status || cat /var/log/hysteria.log | tail -n 20

# ===== [6/6] 智能IP检测 V3.5 NAT修复版 =====
echo -e "${YELLOW}[6/6] IP检测 V3.5...${PLAIN}"

is_private_ip() {
  # 返回 0 表示是内网/保留IP
  case "$1" in
    10.*) return 0 ;;
    192.168.*) return 0 ;;
    127.*) return 0 ;;
    169.254.*) return 0 ;;
    172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;;
    100.64.*|100.65.*|100.66.*|100.67.*|100.68.*|100.69.*|100.70.*|100.71.*|100.72.*|100.73.*|100.74.*|100.75.*|100.76.*|100.77.*|100.78.*|100.79.*|100.80.*|100.81.*|100.82.*|100.83.*|100.84.*|100.85.*|100.86.*|100.87.*|100.88.*|100.89.*|100.90.*|100.91.*|100.92.*|100.93.*|100.94.*|100.95.*|100.96.*|100.97.*|100.98.*|100.99.*|100.100.*|100.101.*|100.102.*|100.103.*|100.104.*|100.105.*|100.106.*|100.107.*|100.108.*|100.109.*|100.110.*|100.111.*|100.112.*|100.113.*|100.114.*|100.115.*|100.116.*|100.117.*|100.118.*|100.119.*|100.120.*|100.121.*|100.122.*|100.123.*|100.124.*|100.125.*|100.126.*|100.127.*) return 0 ;;
    fc00::*|fd00::*|fe80::*|::1|::) return 0 ;;
    0.0.0.0) return 0 ;;
    *) return 1 ;;
  esac
}

get_ssh_ip() {
  # 尝试获取 SSH 会话中，客户端连接的服务器IP
  if [ -n "$SSH_CONNECTION" ]; then echo "$SSH_CONNECTION" | awk '{print $3}'; return; fi
  if [ -d /proc ]; then
    for f in /proc/[0-9]*/environ; do
      [ -f "$f" ] || continue
      ip=$(tr '\0' '\n' < "$f" 2>/dev/null | grep '^SSH_CONNECTION=' | cut -d= -f2 | awk '{print $3}' | tail -n1)
      if echo "$ip" | grep -Eq '^[0-9.]+$' && [ -n "$ip" ]; then echo "$ip"; return; fi
    done
  fi
  # 注意: ss 的 $4 是本地地址，在NAT容器里一定是内网，所以这个只是兜底
  ss -Htn 2>/dev/null | grep ':22' | awk '{print $4}' | cut -d: -f1 | grep -E '^[0-9.]+$' | grep -v '^127\.' | head -n1
}

get_pub_ip() {
  # V3.5 核心修复: 多源 + dig + http降级 + wget
  # 1. dig (最不依赖HTTP)
  if command -v dig >/dev/null 2>&1; then
    for d in "myip.opendns.com @208.67.222.222" "myip.opendns.com @208.67.220.220" "o-o.myaddr.l.google.com @8.8.8.8"; do
      ip=$(dig +short +time=3 +tries=1 $d 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
      if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi
    done
  fi
  # 2. curl 多源
  for api in "https://api.ipify.org" "http://api.ipify.org" "https://ifconfig.me" "http://ifconfig.me" "https://icanhazip.com" "http://icanhazip.com" "https://ipinfo.io/ip" "https://checkip.amazonaws.com" "https://api.my-ip.io/ip"; do
    ip=$(curl -fs --max-time 5 "$api" 2>/dev/null | tr -d '\r' | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
    if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi
  done
  # 3. wget 兜底
  if command -v wget >/dev/null 2>&1; then
    for api in "https://api.ipify.org" "http://ifconfig.me" "http://icanhazip.com"; do
      ip=$(wget -qO- --timeout=5 "$api" 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
      if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi
    done
  fi
}

if [ -n "$CUSTOM_IP" ]; then
  SERVER_IP=$CUSTOM_IP
  echo -e "${GREEN}手动指定 -i: $SERVER_IP${PLAIN}"
else
  SIP=$(get_ssh_ip)
  PIP=$(get_pub_ip)
  echo -e " SSH会话IP: ${YELLOW}${SIP:-未找到}${PLAIN}"
  echo -e " 出口公网IP: ${YELLOW}${PIP:-未知}${PLAIN}"
  echo -e " 检测详情: SSH_CONNECTION=${SSH_CONNECTION:-空}"

  if [ -z "$SIP" ] && [ -n "$PIP" ]; then
    SERVER_IP=$PIP
    echo -e "${GREEN}>> SSH IP为空，采用出口公网IP: $SERVER_IP${PLAIN}"
  elif [ -z "$SIP" ] && [ -z "$PIP" ]; then
    SERVER_IP=""
    echo -e "${RED}>> 无法自动获取任何IP，请使用 -i 参数手动指定${PLAIN}"
  elif is_private_ip "$SIP"; then
    if [ -n "$PIP" ]; then
      SERVER_IP=$PIP
      echo -e "${YELLOW}>> SSH IP $SIP 是内网IP (NAT/LXC)，自动切换到出口公网IP: $SERVER_IP (可连)${PLAIN}"
    else
      SERVER_IP=$SIP
      echo -e "${RED}>> SSH IP $SIP 是内网，但出口IP获取失败，暂用内网IP (客户端可能无法连接，请用 -i 指定公网IP)${PLAIN}"
    fi
  else
    SERVER_IP=$SIP
    echo -e "${GREEN}>> SSH IP $SIP 是公网IP，采用它: $SERVER_IP${PLAIN}"
  fi
fi

# 最终兜底检查
if [ -z "$SERVER_IP" ]; then
  echo -e ""
  echo -e "${RED}========== 获取IP失败 ==========${PLAIN}"
  echo -e "在 NAT VPS / LXC 容器中这是正常的"
  echo -e "请在宿主机执行: ${CYAN}curl -s https://api.ipify.org${PLAIN}"
  echo -e "然后重新安装: ${CYAN}bash $0 -p $HY_PORT -i 你的公网IP${PLAIN}"
  SERVER_IP="YOUR_PUBLIC_IP"
fi

echo ""
echo -e "${GREEN}========== V3.5 完成 ==========${PLAIN}"
echo -e "端口: ${CYAN}${HY_PORT}${PLAIN}"
echo -e "密码: ${CYAN}${HY_PASS}${PLAIN}"
echo -e "IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo -e ""
echo -e "分享链接:"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Alpine-Hy2-V3.5${PLAIN}"
echo -e ""
echo -e "客户端 YAML 示例:"
echo -e "server: ${SERVER_IP}:${HY_PORT}"
echo -e "auth: ${HY_PASS}"
echo -e "tls:"
echo -e "  sni: bing.com"
echo -e "  insecure: true"
echo -e ""
echo -e "记得放行 UDP ${CYAN}${HY_PORT}${PLAIN} - 如果是NAT VPS，请在宿主机做端口转发"
echo -e "宿主机转发示例 (iptables): ${YELLOW}iptables -t nat -A PREROUTING -p udp --dport ${HY_PORT} -j DNAT --to-destination 容器内网IP:${HY_PORT}${PLAIN}"
echo -e ""
if [ "$SERVER_IP" = "YOUR_PUBLIC_IP" ]; then
  echo -e "${RED}注意: 上面链接中的 YOUR_PUBLIC_IP 需要替换为真实公网IP才能使用${PLAIN}"
fi
