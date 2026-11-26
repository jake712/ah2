#!/bin/sh
# Alpine Linux: Hysteria 2 (UDP) + Xray VLESS-REALITY (TCP) 同端口部署脚本

set -e

# ================= 基础配置区 =================
PORT=443
SERVER_IP=$(curl -s4 ip.sb)
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
DEST="www.apple.com:443"
SNI="www.apple.com"

echo ">>> [1/5] 安装基础依赖 (Alpine)..."
apk update && apk add --no-cache curl openssl wget unzip openrc

# ================= 安装 Xray =================
echo ">>> [2/5] 安装 Xray-core..."
if ! command -v xray >/dev/null 2>&1; then
    wget -qO- https://github.com/XTLS/Xray-install/releases/latest/download/install-release.sh | bash
fi

# 生成 REALITY 密钥对
KEYPAIR=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep -oP 'Private key: \K.*')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep -oP 'Public key: \K.*')
SHORT_ID=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 8)

# 写入 Xray 配置
mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$DEST",
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF

# ================= 安装 Hysteria 2 =================
echo ">>> [3/5] 安装 Hysteria 2..."
if ! command -v hysteria >/dev/null 2>&1; then
    ARCH=$(uname -m)
    [ "$ARCH" = "x86_64" ] && HY_ARCH="amd64" || HY_ARCH="arm64"
    wget -qO /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$HY_ARCH
    chmod +x /usr/local/bin/hysteria
fi

# 生成自签证书 (Hysteria 2 需要 TLS)
echo ">>> [4/5] 生成自签证书..."
mkdir -p /etc/hysteria
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem -days 3650 -nodes -subj "/CN=$SNI" 2>/dev/null

# 写入 Hysteria 配置
cat > /etc/hysteria/config.yaml <<EOF
listen: :$PORT
tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem
auth:
  type: password
  password: $HY_PASS
masquerade:
  type: proxy
  proxy:
    url: https://$SNI
    rewriteHost: true
EOF

# ================= 配置 OpenRC 服务 =================
echo ">>> [5/5] 配置 OpenRC 开机自启..."

# Xray 启动脚本
cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
EOF

# Hysteria 启动脚本
cat > /etc/init.d/hysteria <<EOF
#!/sbin/openrc-run
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria.pid"
EOF

chmod +x /etc/init.d/xray /etc/init.d/hysteria
rc-update add xray default
rc-update add hysteria default
/etc/init.d/xray start
/etc/init.d/hysteria start

# ================= 输出节点信息 =================
echo "========================================="
echo "部署完成！请保存以下节点信息："
echo "========================================="
echo "【VLESS-REALITY (TCP $PORT)】"
echo "vless://$UUID@$SERVER_IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#VLESS-Reality"
echo ""
echo "【Hysteria 2 (UDP $PORT)】"
echo "hysteria2://$HY_PASS@$SERVER_IP:$PORT/?sni=$SNI&insecure=1#Hysteria2"
echo "========================================="
