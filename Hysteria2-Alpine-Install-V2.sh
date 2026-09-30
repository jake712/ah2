#!/bin/sh
# Hysteria 2 Alpine V3.6 - NAT/Podman/LXC 低内存兼容版
# 修复: V3.5 在 Podman (search dns.podman) 下 apk add 被 OOM Killed
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

echo -e "${GREEN}=== Hysteria2 Alpine V3.6 低内存/Podman兼容版 ===${PLAIN}"
echo -e "容器ID: $(cat /etc/hostname 2>/dev/null || hostname) | 时间: $(date)"

# ===== [1/6] 基础依赖 - 低内存优化 =====
echo -e "${YELLOW}[1/6] 检查依赖 (低内存模式)...${PLAIN}"

# 显示当前 DNS 和内存
echo -e "当前 resolv.conf:"
cat /etc/resolv.conf | head -n 5
echo -e "内存:"
cat /proc/meminfo | grep -E "MemTotal|MemAvailable" || free -m 2>/dev/null || true

# Podman 容器特殊处理: 不要覆盖 dns.podman 的 resolv.conf
if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "${YELLOW}检测到 Podman 容器 (dns.podman)，保留原有 DNS，不覆盖${PLAIN}"
else
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo -e "${YELLOW}修复 DNS...${PLAIN}"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

# 低内存安装: 按需安装，避免一次装太多被 Killed
ensure_cmd() {
  CMD=$1
  PKG=$2
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo -e "${YELLOW}安装缺失: $CMD ($PKG)...${PLAIN}"
    # --no-cache 不会占用大量内存，避免 apk update
    apk add --no-cache --no-interactive -q "$PKG" 2>&1 || \
    apk add --no-cache "$PKG" 2>&1 || \
    echo -e "${RED}安装 $PKG 失败 (可能被 OOM Killed)，尝试继续...${PLAIN}"
  else
    echo -e "已存在: $CMD"
  fi
}

# 只安装真正需要的，不一次性装一堆
# Podman 容器里 curl/wget/openssl 通常已存在，跳过就不会 Killed
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo -e "${YELLOW}curl 和 wget 都不存在，必须安装一个...${PLAIN}"
  apk add --no-cache --no-interactive -q curl 2>&1 || apk add --no-cache curl 2>&1 || true
fi

ensure_cmd openssl openssl
ensure_cmd dig bind-tools
# ss 不是必须的，失败跳过，避免拉取 iproute2 大包
if ! command -v ss >/dev/null 2>&1; then
  echo -e "${YELLOW}ss 不存在，尝试安装 iproute2 (失败则跳过)...${PLAIN}"
  apk add --no-cache --no-interactive -q iproute2 2>&1 || true
fi
# ca-certificates 小包，单独装
if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
  ensure_cmd update-ca-certificates ca-certificates
  update-ca-certificates 2>/dev/null || true
fi

# ===== [2/6] 参数和路径 =====
echo -e "${YELLOW}[2/6] 初始化参数...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-26169}
if [ -n "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$CUSTOM_PASSWORD
else
  if command -v openssl >/dev/null 2>&1; then
    HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  else
    HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
  fi
fi
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  armv7l|arm) HY_ARCH="arm" ;;
  *) HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log
chmod 700 /etc/hysteria 2>/dev/null || true

# ===== [3/6] 下载 Hysteria2 =====
echo -e "${YELLOW}[3/6] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria

download_ok=0
for i in 1 2 3; do
  echo "尝试下载 $HY_URL (第 $i 次)"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL --max-time 30 -o /tmp/hysteria "$HY_URL"; then download_ok=1; break; fi
  fi
  if command -v wget >/dev/null 2>&1; then
    if wget -q --timeout=30 -O /tmp/hysteria "$HY_URL"; then download_ok=1; break; fi
  fi
  sleep 1
done

if [ "$download_ok" != "1" ] || [ ! -s /tmp/hysteria ]; then
  echo -e "${RED}下载失败，尝试备用镜像...${PLAIN}"
  # 备用: ghfast
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    echo "尝试镜像 $mirror"
    curl -fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
    wget -q --timeout=30 -O /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
  done
fi

if [ ! -s /tmp/hysteria ] || head -c 200 /tmp/hysteria 2>/dev/null | grep -qi "<html"; then
  echo -e "${RED}下载失败，请手动下载:${PLAIN}"
  echo -e "wget -O /usr/local/bin/hysteria $HY_URL"
  ls -lh /tmp/hysteria 2>/dev/null || true
  head -c 500 /tmp/hysteria 2>/dev/null || true
  exit 1
fi

mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria
ls -lh /usr/local/bin/hysteria
# version 可能输出到 stderr
/usr/local/bin/hysteria version 2>&1 || /usr/local/bin/hysteria -v 2>&1 || echo "二进制已就绪"

# ===== [4/6] 生成证书和配置 - 修复 ash 不支持 <() =====
echo -e "${YELLOW}[4/6] 生成配置...${PLAIN}"
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  echo -e "生成自签名证书 (兼容 sh)..."
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  # 兼容方案1: ecparam 直接生成
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || \
  # 方案2: genpkey
  openssl genpkey -algorithm EC -pkeyopt ec_param_enc:named_curve -pkeyopt ec_paramgen_curve:P-256 -out /etc/hysteria/key.key 2>/dev/null || \
  # 方案3: RSA 兜底
  openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null
  
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650 2>/dev/null || \
  openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  
  chmod 600 /etc/hysteria/key.key
  ls -lh /etc/hysteria/
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

# ===== [5/6] 服务 - 兼容 Podman (无 openrc) =====
echo -e "${YELLOW}[5/6] 配置服务...${PLAIN}"

if [ -f /sbin/openrc-run ] || command -v rc-update >/dev/null 2>&1; then
  echo -e "检测到 OpenRC，使用 OpenRC 服务..."
  cat > /etc/init.d/hysteria <<'EOS'
#!/sbin/openrc-run
name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
depend() { need net; after firewall; }
start_pre() {
  checkpath --directory --mode 0755 /run/hysteria
  checkpath --directory --mode 0755 /etc/hysteria
}
EOS
  chmod +x /etc/init.d/hysteria
  rc-update add hysteria default >/dev/null 2>&1 || true
  rc-service hysteria restart 2>&1 || rc-service hysteria start 2>&1 || true
  sleep 2
  rc-service hysteria status 2>&1 || cat /var/log/hysteria.log 2>&1 | tail -n 20
else
  echo -e "${YELLOW}未检测到 OpenRC (Podman/Docker 容器)，使用 nohup 后台运行...${PLAIN}"
  # 杀掉旧进程
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true
  sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
  sleep 2
  ps aux | grep hysteria | grep -v grep || cat /var/log/hysteria.log
  # 创建一个简单的重启脚本
  cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
pkill -f "hysteria.*config.yaml" || true
sleep 1
nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
echo "已重启，日志: tail -f /var/log/hysteria.log"
RESTART
  chmod +x /usr/local/bin/hy2-restart.sh
  echo -e "${GREEN}已创建重启脚本: /usr/local/bin/hy2-restart.sh${PLAIN}"
fi

# 检查端口是否监听
sleep 1
if command -v ss >/dev/null 2>&1; then
  ss -tulpn | grep -E "$HY_PORT|hysteria" || echo "ss 未看到端口，检查日志..."
elif command -v netstat >/dev/null 2>&1; then
  netstat -tulpn | grep "$HY_PORT" || true
fi
echo -e "日志最后20行:"
tail -n 20 /var/log/hysteria.log 2>/dev/null || true

# ===== [6/6] IP检测 V3.6 =====
echo -e "${YELLOW}[6/6] IP检测 V3.6...${PLAIN}"

is_private_ip() {
  case "$1" in
    10.*) return 0 ;;
    192.168.*) return 0 ;;
    127.*) return 0 ;;
    169.254.*) return 0 ;;
    172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;;
    100.64.*|100.65.*|100.66.*|100.67.*|100.68.*|100.69.*|100.70.*|100.71.*|100.72.*|100.73.*|100.74.*|100.75.*|100.76.*|100.77.*|100.78.*|100.79.*|100.80.*|100.81.*|100.82.*|100.83.*|100.84.*|100.85.*|100.86.*|100.87.*|100.88.*|100.89.*|100.90.*|100.91.*|100.92.*|100.93.*|100.94.*|100.95.*|100.96.*|100.97.*|100.98.*|100.99.*|100.100.*|100.101.*|100.102.*|100.103.*|100.104.*|100.105.*|100.106.*|100.107.*|100.108.*|100.109.*|100.110.*|100.111.*|100.112.*|100.113.*|100.114.*|100.115.*|100.116.*|100.117.*|100.118.*|100.119.*|100.120.*|100.121.*|100.122.*|100.123.*|100.124.*|100.125.*|100.126.*|100.127.*) return 0 ;;
    0.0.0.0) return 0 ;;
    *) return 1 ;;
  esac
}

get_ssh_ip() {
  if [ -n "$SSH_CONNECTION" ]; then echo "$SSH_CONNECTION" | awk '{print $3}'; return; fi
  if [ -d /proc ]; then
    for f in /proc/[0-9]*/environ; do
      [ -f "$f" ] || continue
      ip=$(tr '\0' '\n' < "$f" 2>/dev/null | grep '^SSH_CONNECTION=' | cut -d= -f2 | awk '{print $3}' | tail -n1)
      if echo "$ip" | grep -Eq '^[0-9.]+$' && [ -n "$ip" ]; then echo "$ip"; return; fi
    done
  fi
  ss -Htn 2>/dev/null | grep ':22' | awk '{print $4}' | cut -d: -f1 | grep -E '^[0-9.]+$' | grep -v '^127\.' | head -n1
}

get_pub_ip() {
  # 优先 dig
  if command -v dig >/dev/null 2>&1; then
    for d in "myip.opendns.com @208.67.222.222" "myip.opendns.com @208.67.220.220" "o-o.myaddr.l.google.com @8.8.8.8"; do
      ip=$(dig +short +time=3 +tries=1 $d 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
      if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi
    done
  fi
  # curl
  if command -v curl >/dev/null 2>&1; then
    for api in "https://api.ipify.org" "http://api.ipify.org" "https://ifconfig.me" "http://ifconfig.me" "https://icanhazip.com" "https://ipinfo.io/ip" "https://checkip.amazonaws.com"; do
      ip=$(curl -fs --max-time 5 "$api" 2>/dev/null | tr -d '\r' | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
      if [ -n "$ip" ] && ! is_private_ip "$ip"; then echo "$ip"; return; fi
    done
  fi
  # wget
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
  echo -e " SSH_CONNECTION=${SSH_CONNECTION:-空}"

  if [ -z "$SIP" ] && [ -n "$PIP" ]; then
    SERVER_IP=$PIP
    echo -e "${GREEN}>> 采用出口公网IP: $SERVER_IP${PLAIN}"
  elif [ -z "$SIP" ] && [ -z "$PIP" ]; then
    SERVER_IP=""
    echo -e "${RED}>> 无法自动获取任何IP${PLAIN}"
  elif is_private_ip "$SIP"; then
    if [ -n "$PIP" ]; then
      SERVER_IP=$PIP
      echo -e "${YELLOW}>> SSH IP $SIP 是内网 (NAT/Podman)，切换到公网IP: $SERVER_IP${PLAIN}"
    else
      SERVER_IP=$SIP
      echo -e "${RED}>> 内网IP $SIP，但出口IP获取失败，请用 -i 指定${PLAIN}"
    fi
  else
    SERVER_IP=$SIP
    echo -e "${GREEN}>> 采用公网IP: $SERVER_IP${PLAIN}"
  fi
fi

if [ -z "$SERVER_IP" ]; then
  echo -e ""
  echo -e "${RED}========== 获取IP失败 ==========${PLAIN}"
  echo -e "在 Podman/NAT 容器中，请在宿主机执行: curl -s https://api.ipify.org"
  echo -e "然后重新安装: bash $0 -p $HY_PORT -i 你的公网IP"
  SERVER_IP="YOUR_PUBLIC_IP"
fi

echo ""
echo -e "${GREEN}========== V3.6 完成 ==========${PLAIN}"
echo -e "端口: ${CYAN}${HY_PORT}${PLAIN}"
echo -e "密码: ${CYAN}${HY_PASS}${PLAIN}"
echo -e "IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo -e ""
echo -e "分享链接:"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Alpine-Hy2-V3.6-Podman${PLAIN}"
echo -e ""
echo -e "日志: tail -f /var/log/hysteria.log"
echo -e "重启: /usr/local/bin/hy2-restart.sh 或 rc-service hysteria restart"
echo -e "记得放行 UDP ${CYAN}${HY_PORT}${PLAIN}"
if [ "$SERVER_IP" = "YOUR_PUBLIC_IP" ]; then
  echo -e "${RED}注意: 请替换 YOUR_PUBLIC_IP 为真实公网IP${PLAIN}"
fi
