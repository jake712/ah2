#!/bin/sh
# Hysteria 2 Alpine V1.5 - 防封锁加固版 (完整修正版)
# 适配: Alpine Linux 3.20/3.21/3.22+, Karing 客户端完美适配版
# 功能: 区域感知 + 智能优选 SNI + 防主动探测 + 域前置 + 随机密码 + NAT VPS 支持

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

# 参数解析
CUSTOM_PORT=""
CUSTOM_PASSWORD=""
CUSTOM_IP=""
CUSTOM_SNI=""

while getopts "p:w:i:s:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    s) CUSTOM_SNI=$OPTARG ;;
    h) echo "用法: $0 [-p 端口] [-w 认证密码(可选)] [-i 公网IP] [-s 自定义SNI域名]"; exit 0 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

echo -e "${GREEN}=== Hysteria2 Alpine V1.5 防封锁加固版 ===${PLAIN}"
echo -e "容器ID: $(cat /etc/hostname 2>/dev/null || hostname) | 时间: $(date) | 系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2)"

# ===== [1/7] 基础依赖 - Alpine适配 =====
echo -e "${YELLOW}[1/7] 检查并安装 Alpine 依赖...${PLAIN}"

if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "${YELLOW}检测到 Podman (dns.podman)，保留原有 DNS${PLAIN}"
else
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo -e "${YELLOW}修复 DNS...${PLAIN}"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

if ! command -v apk >/dev/null 2>&1; then
  echo -e "${RED}未检测到 apk，不是 Alpine Linux 系统${PLAIN}"; exit 1
fi

echo -e "${YELLOW}更新 apk 软件源并安装必要工具...${PLAIN}"
apk update -q
apk add --no-cache curl openssl bind-tools iproute2 ca-certificates

if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
  update-ca-certificates 2>/dev/null || true
fi

# ===== [2/7] 参数验证与初始化 =====
echo -e "${YELLOW}[2/7] 参数验证与初始化...${PLAIN}"

# 强制要求自定义端口（避免默认端口被封锁）
if [ -z "$CUSTOM_PORT" ]; then
  echo -e "${RED}错误: 必须指定自定义端口! 使用 -p 端口号${PLAIN}"; exit 1
fi

HY_PORT=$CUSTOM_PORT

# 密码：用户提供则使用，否则随机生成
if [ -n "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$CUSTOM_PASSWORD
  echo -e "${GREEN}✔ 使用用户指定密码${PLAIN}"
else
  if command -v openssl >/dev/null 2>&1; then
    HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  else
    HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
  fi
  echo -e "${GREEN}✔ 已随机生成认证密码${PLAIN}"
fi

# 混淆密码随机生成
if command -v openssl >/dev/null 2>&1; then
  HY_OBFS_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
else
  HY_OBFS_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  armv7l|arm) HY_ARCH="arm" ;;
  *) HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /var/log
chmod 700 /etc/hysteria 2>/dev/null || true

# ===== [3/7] 下载 Hysteria2 =====
echo -e "${YELLOW}[3/7] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
download_ok=0
for i in 1 2 3; do
  if command -v curl >/dev/null 2>&1; then
    if curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL"; then download_ok=1; break; fi
  fi
  sleep 1
done

if [ "$download_ok" != "1" ]; then
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    curl -4fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
  done
fi

if [ ! -s /tmp/hysteria ]; then echo -e "${RED}下载失败${PLAIN}"; exit 1; fi
mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

# ===== [4/7] SNI 配置 =====
echo -e "${YELLOW}[4/7] 配置 SNI 域名...${PLAIN}"

if [ -n "$CUSTOM_SNI" ]; then
  OPTIMIZED_SNI="$CUSTOM_SNI"
  echo -e "${GREEN}✔ 使用用户指定的自定义 SNI: ${OPTIMIZED_SNI}${PLAIN}"
else
  # 自动获取 VPS 所在国家代号
  GEO_COUNTRY=$(curl -4s --max-time 3 ipinfo.io/country 2>/dev/null || echo "UNKNOWN")
  echo -e "${CYAN}当前 VPS 归属地检测: [ ${GEO_COUNTRY} ]${PLAIN}"

  # 根据不同国家/地区定制高质量抗封锁候选池
  case "$GEO_COUNTRY" in
    HK|SG|TW|MO)
      SNI_CANDIDATES="cp.cloudflare.com speed.cloudflare.com gateway.icloud.com time.apple.com"
      ;;
    JP|KR)
      SNI_CANDIDATES="dl.google.com update.googleapis.com cp.cloudflare.com www.msftconnecttest.com"
      ;;
    US|CA|DE|GB|FR)
      SNI_CANDIDATES="www.msftconnecttest.com ctldl.windowsupdate.com time.apple.com cp.cloudflare.com"
      ;;
    *)
      SNI_CANDIDATES="www.msftconnecttest.com cp.cloudflare.com connectivitycheck.gstatic.com time.apple.com"
      ;;
  esac

  OPTIMIZED_SNI="www.msftconnecttest.com"
  LOWEST_LATENCY=9999

  for domain in $SNI_CANDIDATES; do
    latency=$(curl -o /dev/null -s -w '%{time_connect}\n' --connect-timeout 2 -m 3 "https://$domain" 2>/dev/null || echo "999")
    is_better=$(awk -v l="$latency" -v min="$LOWEST_LATENCY" 'BEGIN {if (l > 0 && l < min) print 1; else print 0}')
    if [ "$is_better" = "1" ]; then
      LOWEST_LATENCY=$latency
      OPTIMIZED_SNI=$domain
    fi
  done
  echo -e "${GREEN}✔ 区域适配优选最佳 SNI: ${OPTIMIZED_SNI} (节点延迟: ${LOWEST_LATENCY}s)${PLAIN}"
fi

# 生成证书
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=${OPTIMIZED_SNI}" -days 3650 2>/dev/null
  chmod 600 /etc/hysteria/key.key
fi

# 写入配置文件（包含域前置和增强混淆）
cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}

auth:
  type: password
  password: ${HY_PASS}

# 流量混淆配置 (增强版 Salamander, 兼容 Karing)
obfs:
  type: salamander
  salamander:
    password: ${HY_OBFS_PASS}

# 域前置配置 (额外抗封锁层)
masquerade:
  type: proxy
  proxy:
    url: https://${OPTIMIZED_SNI}
    rewriteHost: true

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
EOF

# ===== [5/7] 服务启动（修正版，不再使用无效参数）=====
echo -e "${YELLOW}[5/7] 配置并启动服务...${PLAIN}"

# 创建启动脚本 - 使用 nohup 方式，兼容 OpenRC 缺失环境
cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/sh
# 先杀掉旧进程
pkill -f "/usr/local/bin/hysteria server" 2>/dev/null || true
sleep 1

# 启动服务（仅使用 -c 参数，无无效参数）
nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml \
  > /var/log/hysteria.log 2>&1 &

# 保存 PID
echo $! > /run/hysteria.pid

# 等待并检查
sleep 2
if pgrep -x "hysteria" >/dev/null 2>&1; then
  echo -e "${GREEN}Hysteria2 服务已启动${PLAIN}"
else
  echo -e "${RED}启动失败，请检查日志${PLAIN}"
  cat /var/log/hysteria.log
  exit 1
fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh

# 使用新脚本启动
/usr/local/bin/hy2-restart.sh

# ===== [6/7] 生成节点信息 =====
echo -e "${YELLOW}[6/7] 生成节点连接信息...${PLAIN}"

# 获取服务器IP
SERVER_IP=$CUSTOM_IP
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 5 api.ipify.org || curl -4s --max-time 5 ifconfig.me || echo "your-server-ip")
fi

echo -e "\n${GREEN}================================================"
echo -e "Hysteria 2 节点部署成功！(防封锁加固版)"
echo -e "================================================${PLAIN}"
echo -e "${CYAN}[Karing 客户端手动填入参数]:${PLAIN}"
echo -e "  - ${YELLOW}服务器地址 (Address):${PLAIN} ${SERVER_IP}"
echo -e "  - ${YELLOW}端口 (Port):${PLAIN} ${HY_PORT}"
echo -e "  - ${YELLOW}认证密码 (Password):${PLAIN} ${HY_PASS}"
echo -e "  - ${YELLOW}混淆类型 (Obfs Type):${PLAIN} salamander"
echo -e "  - ${YELLOW}混淆密码 (Obfs Password):${PLAIN} ${HY_OBFS_PASS}"
echo -e "  - ${YELLOW}SNI / 伪装域名:${PLAIN} ${OPTIMIZED_SNI}"
echo -e "  - ${YELLOW}域前置状态:${PLAIN} 开启 (True)"
echo -e "  - ${YELLOW}跳过证书验证:${PLAIN} 开启 (True)"
echo -e "------------------------------------------------"
echo -e "${CYAN}[加密 Hysteria2 节点链接]:${PLAIN}"
echo -e "  hy2://${HY_PASS}@${SERVER_IP}:${HY_PORT}?insecure=1&sni=${OPTIMIZED_SNI}&obfs=salamander&obfs-password=${HY_OBFS_PASS}"
echo -e "  (建议: 在 Karing 中使用完整链接, 或分别填入上述参数)"
echo -e "================================================${PLAIN}"
echo -e "${YELLOW}重要提醒:${PLAIN}"
echo -e "  1. 请妥善保存密码: ${HY_PASS}"
echo -e "  2. 混淆密码: ${HY_OBFS_PASS}"
echo -e "  3. 建议定期更换 SNI 域名以保持有效性"
echo -e "  4. 如出现连接问题，可重新运行本脚本生成新配置"
echo -e "================================================${PLAIN}"

# ===== [7/7] 内存优化建议（可选）=====
echo -e "${YELLOW}[7/7] 内存优化建议（可选执行）${PLAIN}"
echo -e "如需降低 Alpine 内存占用，可手动执行以下命令："
echo -e "  # 1. 清理缓存"
echo -e "  apk clean && rm -rf /tmp/hysteria /var/cache/apk/* /run/hysteria.pid.hidden"
echo -e "  # 2. 调整内核参数"
echo -e "  echo 'vm.swappiness=10' >> /etc/sysctl.conf"
echo -e "  sysctl -p"
echo -e "  # 3. 限制 SSH（如使用）"
echo -e "  echo 'MaxAuthTries 3' >> /etc/ssh/sshd_config"
echo -e "  systemctl restart sshd 2>/dev/null || true"
echo -e "  # 4. 可选：换用 Dropbear 替代 OpenSSH"
echo -e "  apk add dropbear dropbear-scp && rc-service sshd stop && rc-update del sshd default"
echo -e "  rc-service dropbear start && rc-update add dropbear default"
echo -e "================================================${PLAIN}"
