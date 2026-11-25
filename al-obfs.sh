#!/bin/sh
# One-click sing-box installer for Alpine Linux (OpenRC)
# VLESS+Reality / TUIC / Hysteria2
# 生成有效配置，启动成功后输出分享链接
set -eu

# ---------- 默认值 ----------
VLESS_PORT=""
TUIC_PORT=""
HY2_PORT=""
SNI="www.microsoft.com"
SB_VERSION="1.12.7"          # 固定一个稳定版本，避免 grep -oP 在 busybox 下失败
CERT_DIR="/etc/sing-box/certs"
CONFIG_DIR="/etc/sing-box"

# ---------- 参数解析 ----------
usage() {
    cat <<EOF
Usage: $0 [options]
  --vless-port PORT   VLESS+Reality 端口 (默认随机 40000-60000)
  --tuic-port  PORT   TUIC 端口 (默认随机)
  --hy2-port   PORT   Hysteria2 端口 (默认随机)
  --sni        DOMAIN Reality / TLS SNI (默认 www.microsoft.com)
  --help
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --vless-port) VLESS_PORT="$2"; shift 2 ;;
        --tuic-port)  TUIC_PORT="$2";  shift 2 ;;
        --hy2-port)   HY2_PORT="$2";   shift 2 ;;
        --sni)        SNI="$2";        shift 2 ;;
        --help|-h)    usage ;;
        *) echo "Unknown: $1"; usage ;;
    esac
done

# ---------- 架构检测 ----------
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)        SB_ARCH="linux-amd64" ;;
    aarch64|armv8) SB_ARCH="linux-arm64" ;;
    *) echo "[!] Unsupported arch: $ARCH"; exit 1 ;;
esac

# ---------- 安装依赖 (Alpine, OpenRC) ----------
echo "[+] Installing dependencies..."
apk update
apk add --no-cache curl wget tar openssl ca-certificates

# ---------- 下载 sing-box ----------
echo "[+] Downloading sing-box v${SB_VERSION}..."
cd /tmp
TARBALL="sing-box-${SB_VERSION}-${SB_ARCH}.tar.gz"
wget -q "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${TARBALL}" -O "$TARBALL"
tar -xzf "$TARBALL"
cp "sing-box-${SB_VERSION}-${SB_ARCH}/sing-box" /usr/local/bin/sing-box
chmod +x /usr/local/bin/sing-box

# ---------- 生成端口 ----------
gen_port() {
    awk -v min=40000 -v max=60000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'
}
VLESS_PORT="${VLESS_PORT:-$(gen_port)}"
TUIC_PORT="${TUIC_PORT:-$(gen_port)}"
HY2_PORT="${HY2_PORT:-$(gen_port)}"

echo "[+] Ports — VLESS/Reality: $VLESS_PORT, TUIC: $TUIC_PORT, Hysteria2: $HY2_PORT"

# ---------- 生成凭据 ----------
mkdir -p "$CONFIG_DIR" "$CERT_DIR" /var/log/sing-box

# UUID (标准格式)
VLESS_UUID=$(sing-box generate uuid)
TUIC_UUID=$(sing-box generate uuid)

# Reality 密钥对：PrivateKey 留在服务端，PublicKey 给客户端
KEYPAIR=$(sing-box generate reality-keypair)
REALITY_PRIVATE=$(echo "$KEYPAIR" | awk '/PrivateKey:/{print $2}')
REALITY_PUBLIC=$(echo "$KEYPAIR"  | awk '/PublicKey:/{print $2}')
SHORT_ID=$(sing-box generate rand --hex 8)

# 密码
HY2_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=' | head -c 20)
TUIC_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=' | head -c 20)

# ---------- 自签证书 (Hysteria2 + TUIC) ----------
echo "[+] Generating self-signed certificate..."
CERT_FILE="$CERT_DIR/cert.pem"
KEY_FILE="$CERT_DIR/key.pem"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -days 3650 -nodes -subj "/CN=$SNI" \
    -addext "subjectAltName=DNS:$SNI" 2>/dev/null

chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

# ---------- 写配置 ----------
echo "[+] Writing config to $CONFIG_DIR/config.json"

cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "level": "info",
    "output": "/var/log/sing-box/sing-box.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [
        {
          "uuid": "$VLESS_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SNI",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIVATE",
          "short_id": ["$SHORT_ID"]
        }
      }
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "0.0.0.0",
      "listen_port": $TUIC_PORT,
      "users": [
        {
          "uuid": "$TUIC_UUID",
          "password": "$TUIC_PASSWORD"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "alpn": ["h3"],
        "certificate_path": "$CERT_FILE",
        "key_path": "$KEY_FILE"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [
        {
          "password": "$HY2_PASSWORD"
        }
      ],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "alpn": ["h3"],
        "certificate_path": "$CERT_FILE",
        "key_path": "$KEY_FILE"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

# ---------- OpenRC 服务 ----------
echo "[+] Creating OpenRC service..."
cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
description="sing-box multi-protocol proxy"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box/sing-box.log"
error_log="/var/log/sing-box/sing-box.log"

depend() {
    need net
    after firewall
}
EOF

chmod +x /etc/init.d/sing-box
rc-update add sing-box default 2>/dev/null || true

# ---------- 启动 ----------
echo "[+] Starting sing-box..."
rc-service sing-box restart

# 等待端口就绪
sleep 2

if ! rc-service sing-box status | grep -q started; then
    echo "[!] sing-box failed to start. Check: tail -50 /var/log/sing-box/sing-box.log"
    exit 1
fi

# ---------- 获取公网 IP ----------
PUBLIC_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null \
         || curl -4 -s --max-time 5 icanhazip.com 2>/dev/null \
         || echo "YOUR_SERVER_IP")

# ---------- 输出分享链接 ----------
VLESS_NAME="VLESS-Reality-${VLESS_PORT}"
TUIC_NAME="TUIC-${TUIC_PORT}"
HY2_NAME="Hysteria2-${HY2_PORT}"

VLESS_LINK="vless://${VLESS_UUID}@${PUBLIC_IP}:${VLESS_PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${VLESS_NAME}"

TUIC_LINK="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${PUBLIC_IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&sni=${SNI}&insecure=1#${TUIC_NAME}"

HY2_LINK="hysteria2://${HY2_PASSWORD}@${PUBLIC_IP}:${HY2_PORT}/?sni=${SNI}&insecure=1#${HY2_NAME}"

cat <<EOF

============================================================
  sing-box 安装完成 — 分享链接
============================================================

[VLESS + Reality]
$VLESS_LINK

[TUIC v5]
$TUIC_LINK

[Hysteria2]
$HY2_LINK

============================================================
配置文件: $CONFIG_DIR/config.json
日志:     /var/log/sing-box/sing-box.log
服务管理: rc-service sing-box {start|stop|restart|status}
============================================================

重要说明:
  • TUIC 和 Hysteria2 使用自签证书，客户端必须开启 "允许不安全" (insecure)。
  • 如果公网 IP 显示为 YOUR_SERVER_IP，请手动替换为实际 IP。
  • Reality 的 PrivateKey 只保留在服务端，PublicKey (pbk) 已放入链接。
============================================================
EOF

exit 0
