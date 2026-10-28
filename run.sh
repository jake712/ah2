#!/bin/sh

# Reality-SNI-finder - Alpine Linux version
# 原版: https://github.com/meower1/Reality-SNI-finder

main() {
    echo "[*] Updating packages..."
    apk update

    echo "[*] Installing dependencies..."
    apk add --no-cache git python3 py3-pip

    # 如果已存在先刪除，避免 git clone 失敗
    if [ -d "Reality-SNI-finder" ]; then
        echo "[*] Removing old directory..."
        rm -rf Reality-SNI-finder
    fi

    echo "[*] Cloning repo..."
    git clone https://github.com/meower1/Reality-SNI-finder.git

    echo "[*] Installing Python requirements..."
    (cd Reality-SNI-finder && pip3 install --break-system-packages -r requirements.txt)

    echo "[*] Running..."
    (cd Reality-SNI-finder && python3 main.py)
}

main
