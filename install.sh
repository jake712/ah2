#!/bin/sh
# Hysteria 2 Alpine V4.5 - 無宿主機SSH 64M No-SWAP Socat離散跳動版
# 用法: curl -fsSL https://raw.githubusercontent.com/jake712/ah2/main/install.sh | bash -s -- -p 26836 -r "57345,35505,32914,50577,64487" -i 194.110.174.165

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

HY_RANGE=""
while getopts "p:r:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    r) CUSTOM_RANGE=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 主端口] [-r \"離散端口\"] [-w 密碼] [-i 公網IP]"; exit 0 ;;
  esac
done

[ "$(id -u)" != "0" ] && echo -e "${RED}請用 root 運行${PLAIN}" && exit 1
echo -e "${GREEN}=== Hysteria2 Alpine V4.5 無宿主機 No-SWAP Socat版 ===${PLAIN}"
cat /proc/meminfo 2>/dev/null | grep MemTotal || true

# 只裝必須的，不裝 openssl / bind-tools
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  apk add --no-cache --no-progress curl 2>&1 || true
fi
command -v socat >/dev/null 2>&1 || apk add --no-cache --no-progress socat 2>&1 || apk add --no-cache socat 2>&1 || true
command -v iptables >/dev/null 2>&1 || apk add --no-cache --no-progress iptables 2>&1 || true

HY_PORT=${CUSTOM_PORT:-26836}
HY_RANGE=${CUSTOM_RANGE:-57345,35505,32914,50577,64487}
HY_PASS=${CUSTOM_PASSWORD:-$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)}
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) HY_ARCH="amd64";; aarch64|arm64) HY_ARCH="arm64";; *) HY_ARCH="amd64";; esac
mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log; chmod 700 /etc/hysteria

# [3/6] 下載
echo -e "${YELLOW}[3/6] 下載 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
curl -4fsSL --max-time 30 -o /tmp/hysteria "$HY_URL" || wget -qO /tmp/hysteria "$HY_URL"
mv /tmp/hysteria /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria

# [4/6] 內置證書，免openssl
echo -e "${YELLOW}[4/6] 寫入內置證書...${PLAIN}"
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

# [5/6] 無宿主機跳動 - socat模式
echo -e "${YELLOW}[5/6] 配置離散跳動 Socat模式: $HY_RANGE${PLAIN}"
cat > /usr/local/bin/hy2-hop.sh <<EOS
#!/bin/sh
# Socat離散跳動 - 無需 NET_ADMIN
MAIN_PORT=${HY_PORT}
RANGE_LIST="${HY_RANGE}"
pkill -f "socat.*UDP-LISTEN" 2>/dev/null || true
sleep 1
for token in \$(echo "\$RANGE_LIST" | tr ',' ' '); do
  p=\$(echo \$token | cut -d'-' -f1 | tr -d ' ')
  [ -z "\$p" ] && continue
  echo "監聽 \$p -> \$MAIN_PORT"
  nohup socat UDP-LISTEN:\$p,reuseaddr,fork UDP:127.0.0.1:\$MAIN_PORT > /dev/null 2>&1 &
done
# 也嘗試 iptables，如果有權限就雙重保險
for token in \$(echo "\$RANGE_LIST" | tr ',' ' '); do
  ipt=\$(echo \$token | tr '-' ':' | tr -d ' ')
  iptables -t nat -A PREROUTING -p udp --dport \$ipt -j DNAT --to-destination :\$MAIN_PORT 2>/dev/null || true
done
EOS
chmod +x /usr/local/bin/hy2-hop.sh

# 服務
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
depend() { need net; }
start_pre() { /usr/local/bin/hy2-hop.sh 2>/dev/null || true; }
EOS
  chmod +x /etc/init.d/hysteria; rc-update add hysteria default 2>/dev/null
  rc-service hysteria restart 2>/dev/null || rc-service hysteria start 2>/dev/null || true
else
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true; sleep 1
  /usr/local/bin/hy2-hop.sh 2>/dev/null || true
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
sleep 2
ss -ulnp 2>/dev/null | grep -E "${HY_PORT}|socat" || netstat -ulnp 2>/dev/null | grep -E "${HY_PORT}|socat" || true

# [6/6] IP
get_pub_ip(){ curl -4fsSL --max-time 4 https://api4.ipify.org 2>/dev/null || curl -4fsSL --max-time 4 https://ifconfig.me/ip 2>/dev/null; }
SERVER_IP=${CUSTOM_IP:-$(get_pub_ip)}; [ -z "$SERVER_IP" ] && SERVER_IP="YOUR_PUBLIC_IP"
MPORT=$(echo "$HY_RANGE" | tr ',' ',' | tr -d ' ')

echo -e "${GREEN}========== V4.5 無宿主機版 完成 ==========${PLAIN}"
echo -e "主端口: ${CYAN}${HY_PORT}${PLAIN}  離散: ${CYAN}${HY_RANGE}${PLAIN}"
echo -e "密碼: ${CYAN}${HY_PASS}${PLAIN}"
echo -e "單端口測試:"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Hy2-Single${PLAIN}"
echo -e "離散跳動:"
echo -e "${GREEN}hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&mport=${MPORT}&insecure=1#Hy2-Socat-Hop${PLAIN}"
echo -e "${YELLOW}注意：商家面板必須把 ${HY_RANGE} 也轉發給你，否則 socat 監聽了公網也進不來${PLAIN}"
echo -e "日誌: cat /var/log/hysteria.log"
echo -e "檢查: ss -ulnp | grep socat"
