cat << 'EOF' > install_hysteria.sh && chmod +x install_hysteria.sh && ./install_hysteria.sh
#!/bin/bash
set -e

# 顏色定義
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}=== 開始安裝 Hysteria 2 ===${NC}"

# 1. 允許使用者自定義端口與密碼
read -p "請輸入 Hysteria 2 監聽端口 (預設: 443): " PORT
PORT=${PORT:-443}

read -p "請輸入認證密碼 (預設: admin123): " PASSWORD
PASSWORD=${PASSWORD:-admin123}

# 2. 更新系統並安裝依賴
echo -e "${GREEN}[1/6] 更新系統並安裝必要套件...${NC}"
apk update
apk add bash curl openssl tar

# 3. 下載並安裝 Hysteria 二進位檔案
echo -e "${GREEN}[2/6] 下載 Hysteria 主程式...${NC}"
mkdir -p /usr/local/bin
curl -fsSL https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64 -o /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria
/usr/local/bin/hysteria version

# 4. 生成自簽名證書
echo -e "${GREEN}[3/6] 生成自簽名 SSL 證書...${NC}"
mkdir -p /etc/ssl/private
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout "/etc/ssl/private/bing.key" \
  -out "/etc/ssl/private/bing.crt" \
  -days 3650 -subj "/CN=bing.com"
chmod -R 777 /etc/ssl/private

# 5. 建立配置文件
echo -e "${GREEN}[4/6] 寫入配置文件...${NC}"
mkdir -p /etc/hysteria
cat << EOF > /etc/hysteria/config.yaml
listen: :$PORT

tls:
  cert: /etc/ssl/private/bing.crt
  key: /etc/ssl/private/bing.key

auth:
  type: password
  password: "$PASSWORD"

ignoreClientBandwidth: true
EOF

# 6. 建立 OpenRC 服務
echo -e "${GREEN}[5/6] 設定 OpenRC 系統服務...${NC}"
cat << 'EOF' > /etc/init.d/hysteria
#!/sbin/openrc-run

name="Hysteria 2 Service"
description="Hysteria 2 Proxy Server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
EOF
chmod +x /etc/init.d/hysteria

# 7. 啟動服務並設定開機自啟
echo -e "${GREEN}[6/6] 啟動 Hysteria 2 服務...${NC}"
rc-update add hysteria default
rc-service hysteria start

echo -e "${GREEN}=== Hysteria 2 安裝完成！ ===${NC}"
echo "監聽端口: $PORT"
echo "認證密碼: $PASSWORD"
echo "----------------------------------------"
rc-service hysteria status
EOF
