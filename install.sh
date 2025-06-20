#!/bin/bash
# Installer dari GitHub

echo "📥 Mengunduh script..."
curl -L -o /usr/local/bin/v2ray-manager \
https://raw.githubusercontent.com/username-anda/vmess-manager/main/v2ray-manager.sh

chmod +x /usr/local/bin/v2ray-manager

# Buat symlink 'start'
ln -sf /usr/local/bin/v2ray-manager /usr/local/bin/start

echo -e "\n✅ Instalasi selesai! Gunakan perintah:"
echo "start       # Untuk menjalankan menu"
echo "v2ray-manager --update  # Untuk pembaruan"
