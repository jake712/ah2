#!/bin/sh
# Hysteria 2 Alpine V3.4 - 智能IP版 (內網SSH自動用出口IP)
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'

while getopts "p:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 端口] [-w 密碼] [-i 入口IP]"; exit 0 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then echo -e "${RED}請用 root 運行${PLAIN}"; exit 1; fi

cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 223.5.5.5
EOF

get_arch() { case $(uname -m) in x86_64|amd64) echo "amd64";; aarch64|arm64) echo "arm64";; *) echo "amd64";; esac; }
gen_pass() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; }

if [ -z "$CUSTOM_PORT" ]; then
  while true; do
    printf "請輸入端口 (1-65535): "; read INP
    case "$INP" in ''|*[!0-9]*) echo -e "${RED}只能輸入數字${PLAIN}"; continue;; *) if [ "$INP" -ge 1 ] && [ "$INP" -le 65535 ]; then HY_PORT=$INP; break; else echo -e "${RED}範圍 1-65535${PLAIN}"; fi;; esac
  done
else HY_PORT=$CUSTOM_PORT; fi

if [ -z "$CUSTOM_PASSWORD" ]; then HY_PASS=$(gen_pass); echo -e "${YELLOW}自動生成密碼: $HY_PASS${PLAIN}"; else HY_PASS=$CUSTOM_PASSWORD; fi

echo -e "${GREEN}=== 開始安裝 ===${PLAIN}"
apk update
for p in curl wget openssl tar iproute2 file procps openssh; do apk add --no-cache $p || true; done
mkdir -p /usr/local/bin /etc/ssl/private /etc/hysteria /var/log /run/hysteria

ARCH=$(get_arch); [ "$ARCH" = "arm64" ] && BIN="hysteria-linux-arm64" || BIN="hysteria-linux-amd64"
BASE="https://github.com/apernet/hysteria/releases/latest/download/${BIN}"
DEST="/usr/local/bin/hysteria"
URLS="$BASE https://ghps.cc/$BASE https://ghproxy.net/$BASE https://ghfast.top/$BASE https://github.moeyy.xyz/$BASE"

ok=0; for U in $URLS; do echo " 嘗試 $U"; rm -f /tmp/hy.down; if curl -fL --connect-timeout 10 --max-time 120 -o /tmp/hy.down "$U" 2>&1; then if head -c 200 /tmp/hy.down | grep -qi "<html"; then continue; fi; mv /tmp/hy.down $DEST; chmod +x $DEST; ok=1; break; fi; done
[ "$ok" -ne 1 ] && echo -e "${RED}下載失敗${PLAIN}" && exit 1
$DEST version

openssl ecparam -genkey -name prime256v1 -noout -out /etc/ssl/private/bing.key
openssl req -new -x509 -nodes -key /etc/ssl/private/bing.key -out /etc/ssl/private/bing.crt -days 3650 -subj "/CN=bing.com"

cat > /etc/hysteria/config.yaml <<EOC
listen: :${HY_PORT}
tls:
  cert: /etc/ssl/private/bing.crt
  key: /etc/ssl/private/bing.key
auth:
  type: password
  password: ${HY_PASS}
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
EOC

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
start_pre() { checkpath --directory --mode 0755 /run/hysteria; }
EOS
chmod +x /etc/init.d/hysteria; rc-update add hysteria default; rc-service hysteria restart || rc-service hysteria start; sleep 2

# ===== 智能IP檢測 V3.4 =====
is_private_ip() {
  # 返回 0 表示是內網IP
  case "$1" in
    10.*) return 0 ;;
    192.168.*) return 0 ;;
    127.*) return 0 ;;
    169.254.*) return 0 ;;
    172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;;
    100.64.*|100.65.*|100.66.*|100.67.*|100.68.*|100.69.*|100.70.*|100.71.*|100.72.*|100.73.*|100.74.*|100.75.*|100.76.*|100.77.*|100.78.*|100.79.*|100.80.*|100.81.*|100.82.*|100.83.*|100.84.*|100.85.*|100.86.*|100.87.*|100.88.*|100.89.*|100.90.*|100.91.*|100.92.*|100.93.*|100.94.*|100.95.*|100.96.*|100.97.*|100.98.*|100.99.*|100.100.*|100.101.*|100.102.*|100.103.*|100.104.*|100.105.*|100.106.*|100.107.*|100.108.*|100.109.*|100.110.*|100.111.*|100.112.*|100.113.*|100.114.*|100.115.*|100.116.*|100.117.*|100.118.*|100.119.*|100.120.*|100.121.*|100.122.*|100.123.*|100.124.*|100.125.*|100.126.*|100.127.*) return 0 ;;
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
  for api in "https://ifconfig.me" "https://ipinfo.io/ip" "https://icanhazip.com"; do
    ip=$(curl -4s --max-time 3 "$api" 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)
    [ -n "$ip" ] && echo "$ip" && return
  done
}

echo -e "${YELLOW}[6/6] IP檢測...${PLAIN}"
if [ -n "$CUSTOM_IP" ]; then
  SERVER_IP=$CUSTOM_IP
  echo -e "${GREEN}手動指定 -i: $SERVER_IP${PLAIN}"
else
  SIP=$(get_ssh_ip)
  PIP=$(get_pub_ip)
  echo -e " SSH會話IP: ${YELLOW}${SIP:-未找到}${PLAIN}"
  echo -e " 出口公網IP: ${YELLOW}${PIP:-未知}${PLAIN}"
  
  if [ -z "$SIP" ]; then
    SERVER_IP=$PIP
    echo -e "${GREEN}>> 採用出口公網IP: $SERVER_IP${PLAIN}"
  elif is_private_ip "$SIP"; then
    SERVER_IP=$PIP
    echo -e "${YELLOW}>> SSH IP $SIP 是內網IP，自動切換到出口公網IP: $SERVER_IP (可連)${PLAIN}"
  else
    SERVER_IP=$SIP
    echo -e "${GREEN}>> SSH IP $SIP 是公網IP，採用它: $SERVER_IP${PLAIN}"
  fi
fi

echo ""
echo -e "${GREEN}========== 完成 ==========${PLAIN}"
echo -e "hysteria2://${HY_PASS}@${SERVER_IP}:${HY_PORT}/?sni=bing.com&insecure=1#Alpine-Hy2"
echo -e "記得放行 UDP ${HY_PORT}"
