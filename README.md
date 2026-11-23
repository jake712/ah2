23/11 更新 hy2 Gecko 混淆
端口 後台打開的端口

主機IP 

SSH的IP 

*** v2n core核心要改為sing_box 
*** karing  打開設定 > TLS > 跳動證書驗證 打開

Alpine 一鍵安裝Hysteria 2 + AnyTls單端口穩定版(65M Ram可用)
```
curl -fsSL https://raw.githubusercontent.com/jake712/ah2/main/al-obfs-v6.sh | bash -s -- -p 端口 -i 主機出口IP
```

Debian 一鍵安裝Hysteria 2 + AnyTls單端口穩定版(65M Ram可用)
 
```
curl -fsSL https://raw.githubusercontent.com/jake712/ah2/main/db-obfs-v5  | bash -s -- -p 端口 -i 主機出口IP
```

youtube: https://www.youtube.com/watch?v=xwu93mbMqmA

donate: https://jake712.com/?p=120


如果不通可能沒安裝IP TABLE
```
apt-get update && apt-get install -y iptables && systemctl restart hysteria
```



如出現這錯誤

Could not resolve host: raw.githubusercontent.com (Could not contact DNS servers)
```
cat /etc/resolv.conf
# 如果是空的或 127.0.0.11 這種

echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf

ping -c1 1.1.1.1
ping -c1 raw.githubusercontent.com
```
