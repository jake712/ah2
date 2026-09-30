Alpine 一鍵安裝Hysteria 2

port 輸入你的端口
password 輸入你的hy2密碼
外網網址 ssh的IP
```
curl -fsSL https://raw.githubusercontent.com/jake712/ah2/main/Hysteria2-Alpine-Install-V2.sh | bash -s -- -p port -w 'password'
```

youtube: https://www.youtube.com/watch?v=xwu93mbMqmA

donate: https://jake712.com/?p=120

指定出口IP版
```
curl -fsSL https://raw.githubusercontent.com/jake712/ah2/main/Hysteria2-Alpine-Install-V3.sh | bash -s -- -p 端口 -w '密碼' -i 外網網址
```
65M小雞要安裝临时建一个 Swap

```
fallocate -l 512M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=512
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
free -h
```

Could not resolve host: raw.githubusercontent.com (Could not contact DNS servers)
```
cat /etc/resolv.conf
# 如果是空的或 127.0.0.11 這種

echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf

ping -c1 1.1.1.1
ping -c1 raw.githubusercontent.com
```
