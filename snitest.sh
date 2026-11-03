cat << 'EOF' > test-sni.sh
#!/bin/sh

# 候選大廠高質量偽裝域名池
DOMAINS="www.bing.com aws.amazon.com cdn.shopify.com azure.microsoft.com www.cloudflare.com dl.google.com itunes.apple.com www.microsoft.com"

echo "========================================================"
echo "          VPS 候選 SNI 域名連通性與延遲測試工具          "
echo "========================================================"
printf "%-25s | %-10s | %-12s\n" "候選域名 (SNI)" "HTTP 狀態" "總耗時 (秒)"
printf "--------------------------------------------------------\n"

for domain in $DOMAINS; do
    # 使用 curl 測試 IPv4 下的 HTTPS 請求，抓取狀態碼與總耗時（超時限制 3 秒）
    result=$(curl -4 -o /dev/null -s -w "%{http_code} %{time_total}" --max-time 3 "https://$domain" 2>/dev/null)
    exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        code=$(echo "$result" | awk '{print $1}')
        time=$(echo "$result" | awk '{print $2}')
        printf "%-25s | %-10s | %-12ss\n" "$domain" "$code" "$time"
    else
        printf "%-25s | %-10s | %-12s\n" "$domain" "連接失敗/超時" "N/A"
    fi
done
echo "========================================================"
echo "提示：優先選擇耗時最短且 HTTP 狀態碼正常（如 200, 301, 403）的域名作為 -s 參數。"
EOF

chmod +x test-sni.sh
./test-sni.sh
rm -f test-sni.sh
