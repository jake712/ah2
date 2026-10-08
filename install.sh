#!/bin/sh
# Hysteria 2 Alpine V4.3 - 64M超低內存離散跳動版 - 免openssl
# 用法: curl -fsSL https://raw.githubusercontent.com/jake712/ah2/main/Install.sh | bash -s -- -p 26836 -r "20001,20005,30001" -i 160.187.0.21

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

HY_RANGE=""
while getopts "p:r:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    r) CUSTOM_RANGE=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 主端口] [-r \"離散端口\"] [-w 密碼] [-i IP]"; exit 0 ;;
  esac
done

[ "$(id -u)" != "0" ] && echo -e "${RED}請用 root 運行${PLAIN}" && exit 1

MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 999999)
echo -e "${GREEN}=== Hysteria2 Alpine V4.3 64M專用版 ===${PLAIN}"
echo -e "MemTotal: ${MEM_KB}KB | 容器: $(cat /etc/hostname 2>/dev/null)"

# 64M 超低內存不嘗試在容器內建 SWAP，會直接斷連
if [ "$MEM_KB" -lt 100000 ]; then
  echo -e "${YELLOW}超低內存模式：跳過 SWAP 和 openssl 安裝，使用內置證書${PLAIN}"
  echo -e "${YELLOW}建議：在宿主機執行: lxc config set $(hostname) limits.memory 256MB 然後 lxc restart $(hostname)${PLAIN}"
fi
rm -rf /var/cache/apk/* 2>/dev/null || true

# 只裝必須的
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  apk add --no-cache --no-progress curl 2>&1 || true
fi
command -v iptables >/dev/null 2>&1 || apk add --no-cache --no-progress iptables 2>&1 || true

HY_PORT=${CUSTOM_PORT:-26836}
HY_RANGE=${CUSTOM_RANGE:-20001,20005,30001,40001,50001}
if [ -n "$CUSTOM_PASSWORD" ]; then HY_PASS=$CUSTOM_PASSWORD
else HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16); fi
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"

ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log; chmod 700 /etc/hysteria

# 下載
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
echo -e "${YELLOW}[3/6] 下載 Hysteria2...${PLAIN}"
curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" || wget -qO /tmp/hysteria "$HY_URL"
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria

# 證書 - 免openssl，直接用內置
echo -e "${YELLOW}[4/6] 寫入內置證書 (免openssl)...${PLAIN}"
cat > /etc/hysteria/key.key <<'KEY'
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIEz5lPVglnHctjQNCODLQGhvI9M7hDzJ3eQz1wqh8atooAoGCCqGSM49
AwEHoUQDQgAEXez2cNkjNoPwAC3fEQTr5knwEnqGlPxbUTFQUImf9GiYuBHs5jCK
PGY+0CWaKV7TQMlrzrjgk4DD1dckxB9Eyw==
-----END EC PRIVATE KEY-----
KEY
cat > /etc/hysteria/cert.crt <<'CERT'
-----BEGIN CERTIFICATE-----
MIIBPTCB5aADAgECAhRP81E1j7+8pgsScNZwNt58d+bdqTAKBggqhkjOPQQDAjAT
MREwDwYDVQQDDAhiaW5nLmNvbTAeFw0yNjEwMDcwNjM2MTRaFw0zNjEwMDUwNjM2
MTRaMBMxETAPBgNVBAMMCGJpbmcuY29tMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcD
QgAEXez2cNkjNoPwAC3fEQTr5knwEnqGlPxbUTFQUImf9GiYuBHs5jCKPGY+0CWa
KV7TQMlrzrjgk4DD1dckxB9Ey6MXMBUwEwYDVR0RBAwwCoIIYmluZy5jb20wCgYI
KoZIzj0EAwIDRwAwRAIgH73JDNDHvPYD23A/3nKR9RgBRSq9YaVwjKpX+NJvWRkC
ICyfRBvBNWdejFW6rbhSNB9+yhGbghqqYZpFRdtNVxj6
-----END CERTIFICATE-----
CERT
chmod 600 /etc/hysteria/key.key

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

# 離散跳動
echo -e "${YELLOW}[5/6] 配置離散跳動...${PLAIN}"
echo "#!/bin/sh" > /usr/local/bin/hy2-iptables.sh
echo "$HY_RANGE" | tr ',' '\n' | while read -r token; do
  token=$(echo "$token" | tr -d ' ' | tr -d '\r'); [ -z "$token" ] && continue
  ipt_token=$(echo "$token" | tr '-' ':')
  iptables -t nat -D PREROUTING -p udp --dport "$ipt_token" -j DNAT --to-destination :${HY_PORT} 2>/dev/null || true
  iptables -t nat -A PREROUTING -p udp --dport "$ipt_token" -j DNAT --to-destination :${HY_PORT} 2>/dev/null || echo "宿主機需執行: iptables -t nat -A PREROUTING -p udp --dport $ipt_token -j DNAT --to :$HY_PORT"
  echo "iptables -t nat -C PREROUTING -p udp --dport $ipt_token -j DNAT --to-destination :${HY_PORT} 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport $ipt_token -j DNAT --to-destination :${HY_PORT}" >> /usr/local/bin/hy2-iptables.sh
done
chmod +x /usr/local/bin/hy2-iptables.sh

if [ -f /sbin/openrc-run ]; then
  cat > /etc/init.d/hysteria <<'EOS'
#!/sbin/openrc-run
name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
start_pre() { /usr/local/bin/hy2-iptables.sh 2>/dev/null || true; }
EOS
  chmod +x /etc/init.d/hysteria; rc-update add hysteria default 2>/dev/null; rc-service hysteria restart 2>/dev/null || rc-service hysteria start 2>/dev/null || true
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1
  /usr/local/bin/hy2-iptables.sh 2>/dev/null || true
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
sleep 1

# IP檢測 - 只用curl，不用dig
get_pub_ip(){ curl -4fsSL --max-time 4 https://api4.ipify.org 2>/dev/null || curl -4fsSL --max-time 4 https://ifconfig.me/ip 2>/dev/null; }
SERVER_IP=${CUSTOM_IP:-$(get_pub_ip)}; [ -z "$SERVER_IP" ] && SERVER_IP="YOUR_PUBLIC_IP"
MPORT=$(echo "$HY_RANGE" | tr ':' '-' | tr -d ' ')

echo -e "${GREEN}========== V4.3 完成 ==========${PLAIN}"
echo -e "主端口: ${CYAN}${HY_PORT}${PLAIN}  離散: ${CYAN}${HY_RANGE}${PLAIN}"
echo -e "密碼: ${CYAN}${HY_PASS}${PLAIN}  IP: ${CYAN}${SERVER_IP}${PLAIN}"
echo -e "離散跳動鏈:"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&mport=${MPORT}&insecure=1#Hy2-64M-Hop${PLAIN}"
