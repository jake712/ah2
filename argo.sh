#!/bin/sh
#=============================================================
# Alpine Linux 一键安装脚本
#   组件：Argo 临时隧道(cloudflared) + Xray(Vmess+WS) + Hysteria2
#   特性：Vmess 经 Argo 隧道出网(TCP/443)
#         Hysteria2 直连服务器 UDP 端口
#         两者可共用「同一个端口号」(TCP / UDP 互不冲突)
#   环境：Alpine 3.16+ / OpenRC / x86_64 / aarch64
#   用法：sh alpine-argo-hy2.sh [install|uninstall|info|restart] [选项]
#=============================================================
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[1;36m'; N='\033[0m'
info(){ printf "${G}[*]${N} %s\n" "$*"; }
warn(){ printf "${Y}[!]${N} %s\n" "$*"; }
err(){  printf "${R}[x]${N} %s\n" "$*" >&2; }
die(){  err "$*"; exit 1; }

# ---------- 路径与默认值 ----------
XRAY_BIN=/usr/local/bin/xray
HY_BIN=/usr/local/bin/hysteria
CF_BIN=/usr/local/bin/cloudflared
XRAY_CFG=/usr/local/etc/xray/config.json
XRAY_LOG=/var/log/xray
HY_CFG=/etc/hysteria/config.yaml
HY_CERT=/etc/hysteria/cert.pem
HY_KEY=/etc/hysteria/key.pem
HY_LOG=/var/log/hysteria.log
CF_LOG=/var/log/cloudflared.log
STATE=/etc/alpine-argo/state.conf

DEF_PORT=8443
DEF_SNI=www.bing.com
DEF_NAME=Alpine-Argo

ACTION=install
OPT_PORT=""; OPT_VMESS_PORT=""; OPT_HY_PORT=""; OPT_UUID=""; OPT_SNI=""; OPT_NAME=""

usage(){
cat <<'EOF'
用法: sh alpine-argo-hy2.sh [动作] [选项]

动作:
  install     安装并启动 (默认)
  uninstall   卸载
  info        查看当前节点链接 / 配置
  restart     重启全部服务

选项:
  -p, --port N         同时指定 Vmess 与 Hysteria2 的端口号 (默认 8443)
      --vmess-port N   单独指定 Vmess(本地 TCP)端口
      --hy2-port N     单独指定 Hysteria2(UDP)端口
  -u, --uuid UUID      指定 Vmess UUID
      --sni NAME       指定 Hysteria2 自签证书的 SNI/CN (默认 www.bing.com)
  -n, --name NAME      节点显示名称
  -h, --help           显示本帮助

示例:
  sh alpine-argo-hy2.sh                       # 默认 8443 同端口
  sh alpine-argo-hy2.sh -p 2087               # 双协议都用 2087
  sh alpine-argo-hy2.sh --hy2-port 443        # 仅 hy2 用 443，vmess 用 8443
EOF
}

# ---------- 小工具 ----------
rand_hex(){ od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

gen_uuid(){
  h=$(rand_hex 16)
  printf '%s-%s-%s-%s-%s\n' \
    "$(printf %s "$h" | cut -c1-8)"  \
    "$(printf %s "$h" | cut -c9-12)" \
    "$(printf %s "$h" | cut -c13-16)" \
    "$(printf %s "$h" | cut -c17-20)" \
    "$(printf %s "$h" | cut -c21-32)"
}

check_port(){
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

need_root(){
  [ "$(id -u)" = "0" ] || die "请使用 root 运行此脚本"
  [ -f /etc/alpine-release ] || die "此脚本仅适用于 Alpine Linux"
}

argo_host_from_log(){
  grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null \
    | tail -n1 | sed 's#https://##'
}

# ---------- 安装 ----------
do_install(){
  need_root

  case "$(uname -m)" in
    x86_64|amd64)   XRZIP="Xray-linux-64.zip";            HYB="hysteria-linux-amd64"; CFB="cloudflared-linux-amd64" ;;
    aarch64|arm64)  XRZIP="Xray-linux-arm64-v8a.zip";     HYB="hysteria-linux-arm64"; CFB="cloudflared-linux-arm64" ;;
    *) die "不支援的 CPU 架构: $(uname -m)" ;;
  esac

  # 读取旧状态（保留 UUID/密码/路径），再套用命令行参数
  PORT=""; VMESS_PORT=""; HY_PORT=""; UUID=""; WSPATH=""; HYPASS=""; SNI=""; NAME=""; ARGO_HOST=""
  [ -f "$STATE" ] && . "$STATE"
  PORT=${OPT_PORT:-${PORT:-$DEF_PORT}}
  VMESS_PORT=${OPT_VMESS_PORT:-${VMESS_PORT:-$PORT}}
  HY_PORT=${OPT_HY_PORT:-${HY_PORT:-$PORT}}
  SNI=${OPT_SNI:-${SNI:-$DEF_SNI}}
  NAME=${OPT_NAME:-${NAME:-$DEF_NAME}}
  UUID=${OPT_UUID:-${UUID:-$(gen_uuid)}}
  WSPATH=${WSPATH:-/$(rand_hex 6)}
  HYPASS=${HYPASS:-$(rand_hex 8)}

  check_port "$PORT"       || die "端口无效: $PORT"
  check_port "$VMESS_PORT" || die "Vmess 端口无效: $VMESS_PORT"
  check_port "$HY_PORT"    || die "Hysteria2 端口无效: $HY_PORT"

  info "安装依赖 (curl unzip openssl ca-certificates) ..."
  apk add --no-cache curl unzip openssl ca-certificates >/dev/null 2>&1 \
    || die "apk 安装依赖失败，请检查网络或软件源"

  info "停止旧服务 ..."
  for s in cloudflared hysteria xray; do rc-service "$s" stop >/dev/null 2>&1; done

  TMP=$(mktemp -d) || die "无法创建临时目录"
  trap 'rm -rf "$TMP"' EXIT

  info "下载 Xray-core ..."
  curl -fsSL --retry 3 -o "$TMP/xray.zip" \
    "https://github.com/XTLS/Xray-core/releases/latest/download/$XRZIP" \
    || die "Xray 下载失败"
  unzip -oq "$TMP/xray.zip" -d "$TMP/xray" || die "Xray 解压失败"
  cp "$TMP/xray/xray" "$XRAY_BIN" && chmod 755 "$XRAY_BIN" || die "安装 Xray 失败"

  info "下载 Hysteria2 ..."
  curl -fsSL --retry 3 -o "$HY_BIN" \
    "https://github.com/apernet/hysteria/releases/latest/download/$HYB" \
    || die "Hysteria2 下载失败"
  chmod 755 "$HY_BIN"

  info "下载 cloudflared ..."
  curl -fsSL --retry 3 -o "$CF_BIN" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/$CFB" \
    || die "cloudflared 下载失败"
  chmod 755 "$CF_BIN"

  mkdir -p /usr/local/etc/xray "$XRAY_LOG" /etc/hysteria /etc/alpine-argo

  if [ ! -f "$HY_CERT" ] || [ ! -f "$HY_KEY" ]; then
    info "生成自签 TLS 证书 (CN=$SNI) ..."
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
      -keyout "$HY_KEY" -out "$HY_CERT" -subj "/CN=$SNI" >/dev/null 2>&1 \
      || die "证书生成失败"
  fi

  info "写入 Xray 配置 ..."
  cat > "$XRAY_CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vmess-ws",
      "listen": "127.0.0.1",
      "port": ${VMESS_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [ { "id": "${UUID}", "alterId": 0, "security": "auto" } ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "${WSPATH}" }
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": {} }
  ]
}
EOF

  info "写入 Hysteria2 配置 ..."
  cat > "$HY_CFG" <<EOF
listen: :${HY_PORT}

tls:
  cert: ${HY_CERT}
  key: ${HY_KEY}

auth:
  type: password
  password: ${HYPASS}
EOF

  info "写入 OpenRC 服务 ..."
  cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
name="xray"
description="Xray (VMess+WS for Argo Tunnel)"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"
depend() { need net; after firewall; }
EOF

  cat > /etc/init.d/hysteria <<'EOF'
#!/sbin/openrc-run
name="hysteria"
description="Hysteria2 Server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
depend() { need net; }
EOF

  cat > /etc/init.d/cloudflared <<EOF
#!/sbin/openrc-run
name="cloudflared"
description="Cloudflare Argo Quick Tunnel"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate --url http://127.0.0.1:${VMESS_PORT}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${CF_LOG}"
error_log="${CF_LOG}"
depend() { need net; after xray; }
EOF

  chmod 755 /etc/init.d/xray /etc/init.d/hysteria /etc/init.d/cloudflared

  info "注册并启动服务 ..."
  rc-update add xray default        >/dev/null 2>&1
  rc-update add hysteria default    >/dev/null 2>&1
  rc-update add cloudflared default >/dev/null 2>&1

  [ -f "$CF_LOG" ] && : > "$CF_LOG"

  rc-service xray start        >/dev/null 2>&1 || warn "xray 启动失败，请看 /var/log/xray/error.log"
  rc-service hysteria start    >/dev/null 2>&1 || warn "hysteria 启动失败，请看 $HY_LOG"
  rc-service cloudflared start >/dev/null 2>&1 || warn "cloudflared 启动失败，请看 $CF_LOG"

  info "等待 Argo 临时隧道建立 ..."
  i=0; ARGO_HOST=""
  while [ "$i" -lt 60 ]; do
    ARGO_HOST=$(argo_host_from_log)
    [ -n "$ARGO_HOST" ] && break
    i=$((i+1)); sleep 1
  done
  [ -n "$ARGO_HOST" ] || warn "未取得 Argo 域名，请稍后运行: sh $0 info"

  cat > "$STATE" <<EOF
PORT=${PORT}
VMESS_PORT=${VMESS_PORT}
HY_PORT=${HY_PORT}
UUID=${UUID}
WSPATH=${WSPATH}
HYPASS=${HYPASS}
SNI=${SNI}
NAME=${NAME}
ARGO_HOST=${ARGO_HOST}
EOF
  chmod 600 "$STATE"

  print_result
}

# ---------- 输出结果 ----------
print_result(){
  [ -f "$STATE" ] || die "尚未安装，找不到 $STATE （请先运行 install）"
  . "$STATE"

  h=$(argo_host_from_log); [ -n "$h" ] && ARGO_HOST="$h"

  IP=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null)
  [ -z "${IP:-}" ] && IP=$(curl -fsS --max-time 8 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\n')
  [ -z "${IP:-}" ] && IP="<服务器公网IP>"

  vmess_host=${ARGO_HOST:-"<等待Argo域名>"}

  vjson=$(printf '{"v":"2","ps":"%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s","alpn":"","fp":""}' \
    "$NAME" "$vmess_host" "$UUID" "$vmess_host" "$WSPATH" "$vmess_host")
  vlink="vmess://$(printf %s "$vjson" | base64 | tr -d '\n')"
  hlink="hysteria2://${HYPASS}@${IP}:${HY_PORT}/?sni=${SNI}&insecure=1#${NAME}-hy2"

  echo
  printf "${C}==================== 安装完成 ====================${N}\n"
  echo
  printf "${G}【Vmess (Argo 临时隧道)】${N}\n"
  printf '  %s\n\n' "$vlink"
  printf "${G}【Hysteria2 (直连 UDP)】${N}\n"
  printf '  %s\n\n' "$hlink"
  printf "${Y}---------- 手动填写参数 ----------${N}\n"
  printf '  Vmess Host : %s\n'  "$vmess_host"
  printf '  Vmess Port : 443  (TLS)\n'
  printf '  Vmess UUID : %s\n'  "$UUID"
  printf '  Vmess Path : %s   (WS)\n' "$WSPATH"
  printf '  HY2 服务器 : %s\n'  "$IP"
  printf '  HY2 端口   : %s  (UDP)\n' "$HY_PORT"
  printf '  HY2 密码   : %s\n'  "$HYPASS"
  printf '  HY2 SNI    : %s  (需跳过证书验证 insecure=1)\n' "$SNI"
  echo
  printf "${Y}---------- 服务状态 ----------${N}\n"
  for s in xray hysteria cloudflared; do
    if rc-service "$s" status >/dev/null 2>&1; then printf "  %-12s : 运行中\n" "$s"; else printf "  %-12s : 未运行\n" "$s"; fi
  done
  echo
  warn "Argo 临时隧道域名每次重启都会改变，Vmess 链接会失效，重启后请运行 info 重新获取。"
  warn "Hysteria2 使用自签证书，客户端必须开启「跳过证书验证 / insecure」。"
  warn "请确认防火墙与云厂商安全组已放行 UDP ${HY_PORT}。"
  echo
}

# ---------- 卸载 ----------
do_uninstall(){
  need_root
  info "停止并移除服务 ..."
  for s in cloudflared hysteria xray; do
    rc-service "$s" stop >/dev/null 2>&1
    rc-update del "$s" default >/dev/null 2>&1
    rm -f "/etc/init.d/$s"
  done
  rm -f "$XRAY_BIN" "$HY_BIN" "$CF_BIN"
  rm -rf /usr/local/etc/xray /etc/hysteria /etc/alpine-argo "$XRAY_LOG"
  rm -f "$HY_LOG" "$CF_LOG"
  info "卸载完成。"
}

# ---------- 重启 ----------
do_restart(){
  need_root
  info "重启服务 ..."
  rc-service xray restart >/dev/null 2>&1 || warn "xray 重启失败"
  rc-service hysteria restart >/dev/null 2>&1 || warn "hysteria 重启失败"
  [ -f "$CF_LOG" ] && : > "$CF_LOG"
  rc-service cloudflared restart >/dev/null 2>&1 || warn "cloudflared 重启失败"
  info "等待 Argo 域名 ..."
  i=0; host=""
  while [ "$i" -lt 60 ]; do host=$(argo_host_from_log); [ -n "$host" ] && break; i=$((i+1)); sleep 1; done
  if [ -n "$host" ] && [ -f "$STATE" ]; then
    sed -i "s#^ARGO_HOST=.*#ARGO_HOST=${host}#" "$STATE"
  fi
  print_result
}

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    install|uninstall|info|restart) ACTION="$1"; shift ;;
    -p|--port)        [ $# -ge 2 ] || die "$1 缺少参数"; OPT_PORT=$2; shift 2 ;;
    --vmess-port)     [ $# -ge 2 ] || die "$1 缺少参数"; OPT_VMESS_PORT=$2; shift 2 ;;
    --hy2-port|--hy-port) [ $# -ge 2 ] || die "$1 缺少参数"; OPT_HY_PORT=$2; shift 2 ;;
    -u|--uuid)        [ $# -ge 2 ] || die "$1 缺少参数"; OPT_UUID=$2; shift 2 ;;
    --sni)            [ $# -ge 2 ] || die "$1 缺少参数"; OPT_SNI=$2; shift 2 ;;
    -n|--name)        [ $# -ge 2 ] || die "$1 缺少参数"; OPT_NAME=$2; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) die "未知参数: $1 （使用 --help 查看说明）" ;;
  esac
done

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  info)      print_result ;;
  restart)   do_restart ;;
  *) usage ;;
esac
