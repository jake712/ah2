Alpine 一鍵安裝Hysteria 2

端口 後台打開的端口
主機IP SSH的IP

```
curl -fsSL https://raw.githubusercontent.com/jake712/ah2/main/Hysteria2-Alpine-Install-V2.sh | bash -s -- -p 端口 -i 主機IP
```

youtube: https://www.youtube.com/watch?v=xwu93mbMqmA

donate: https://jake712.com/?p=120


如出現這錯誤

Could not resolve host: raw.githubusercontent.com (Could not contact DNS servers)
```
cat /etc/resolv.conf
# 如果是空的或 127.0.0.11 這種

echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf

ping -c1 1.1.1.1
ping -c1 raw.githubusercontent.com
```
