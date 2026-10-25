#!/bin/bash

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 確保以 root 權限執行
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}請使用 root 權限執行此腳本 (例如: sudo bash install.sh)${NC}"
   exit 1
fi

echo -e "${GREEN}=== Xray-core XHTTP + REALITY 加強版安裝腳本 ===${NC}"

# 1. 處理端口設定 (命令列參數 1 或互動輸入)
PORT=${1:-""}
if [ -z "$PORT" ]; then
    read -p "請輸入 XHTTP 運行端口 [預設 443]: " PORT
    PORT=${PORT:-443}
fi
echo -e "${YELLOW}-> 將使用端口: ${PORT}${NC}"

# 2. 顯示本機可用 IP 列表供參考
echo -e "${YELLOW}當前伺服器偵測到的可用 IP 列表：${NC}"
ip -4 addr show | grep inet | awk '{print $2}' | cut -d/ -f1
echo -e "--------------------------------------------------"

# 3. 處理出口 IP 設定 (命令列參數 2 或互動輸入)
OUTBOUND_IP=${2:-""}
if [ -z "$OUTBOUND_IP" ]; then
    read -p "請輸入要指定的出口 IP (若留空則使用系統預設路由): " OUTBOUND_IP
fi

if [ -n "$OUTBOUND_IP" ]; then
    echo -e "${YELLOW}-> 已指定出口 IP: ${OUTBOUND_IP}${NC}"
    SEND_THROUGH_LINE="\"sendThrough\": \"${OUTBOUND_IP}\","
else
    echo -e "${YELLOW}-> 未指定出口 IP，將使用系統預設 IP${NC}"
    SEND_THROUGH_LINE=""
fi

# 4. 安裝 / 更新 Xray-core 主程式
echo -e "${YELLOW}-> 正在安裝 / 更新 Xray-core 主程式...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 5. 自動生成 REALITY 所需的安全金鑰與隨機路徑
echo -e "${YELLOW}-> 正在生成 REALITY 安全憑證與隨機特徵...${NC}"
UUID=$(/usr/local/bin/xray uuid)
X25519_OUT=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$X25519_OUT" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$X25519_OUT" | grep "Public key:" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)
PATH_STR="/$(openssl rand -hex 6)"
SNI="dl.google.com" # 偽裝目標網域

# 建立設定檔目錄
mkdir -p /usr/local/etc/xray

# 6. 寫入 Xray 設定檔 (VLESS + XHTTP + REALITY)
cat << EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}",
            "www.google.com"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        },
        "xhttpSettings": {
          "mode": "auto",
          "path": "${PATH_STR}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      ${SEND_THROUGH_LINE}
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF

# 7. 檢查並放行防火牆 (UFW)
if command -v ufw &> /dev/null; then
    ufw allow ${PORT}/tcp
    echo -e "${YELLOW}-> 已透過 UFW 開放 TCP 端口 ${PORT}${NC}"
fi

# 8. 重啟並啟用 Xray 服務
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 9. 取得公網 IP 並組合客戶端分享連結
IP=$(curl -s ifconfig.me || curl -s api.ipify.org)
SHARE_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${PATH_STR}#XHTTP-Reality"

echo -e "\n${GREEN}==================================================${NC}"
echo -e "${GREEN}   Xray XHTTP + REALITY 加強版安裝成功！          ${NC}"
echo -e "${GREEN}==================================================${NC}"
echo -e "伺服器 IP   : ${YELLOW}${IP}${NC}"
echo -e "指定出口 IP   : ${YELLOW}${OUTBOUND_IP:-預設路由}${NC}"
echo -e "連接端口    : ${YELLOW}${PORT}${NC}"
echo -e "UUID        : ${YELLOW}${UUID}${NC}"
echo -e "公鑰 (PBK)  : ${YELLOW}${PUBLIC_KEY}${NC}"
echo -e "Short ID    : ${YELLOW}${SHORT_ID}${NC}"
echo -e "--------------------------------------------------"
echo -e "${GREEN}【客戶端分享連結】(可直接複製並匯入 Karing / v2rayN)：${NC}"
echo -e "${YELLOW}${SHARE_LINK}${NC}"
echo -e "==================================================${NC}"
