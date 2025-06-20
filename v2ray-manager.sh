#!/bin/bash

set -e

V2RAY_CONFIG="/usr/local/etc/v2ray/config.json"
NGINX_CONFIG="/etc/nginx/sites-available/v2ray"
INSTALL_PATH="/usr/local/bin/start"

# Fungsi untuk install dependensi
install_dependencies() {
    echo "Memulai instalasi dependensi..."
    apt update -y
    apt install -y \
        jq \
        curl \
        wget \
        gnupg2 \
        ca-certificates \
        lsb-release \
        dnsutils \
        nginx \
        certbot \
        python3-certbot-nginx
    
    echo "✅ Dependensi berhasil diinstall"
}

# Fungsi install V2Ray
install_v2ray() {
    echo "Memulai instalasi V2Ray..."
    curl -O https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh
    bash install-release.sh
    echo "✅ V2Ray berhasil diinstall"
}

# Fungsi setup awal
initial_setup() {
    # Install semua dependensi terlebih dahulu
    install_dependencies
    install_v2ray
    
    # Setelah semua terinstall, minta input domain
    read -p "Masukkan domain anda (sudah diarahkan ke IP VPS): " domain
    read -p "Masukkan email Anda untuk notifikasi SSL: " email

    # Verifikasi DNS domain
    echo "Memverifikasi domain $domain..."
    resolved_ip=$(dig +short "$domain" | tail -n1)
    vps_ip=$(curl -s ifconfig.me)
    echo "Domain mengarah ke: $resolved_ip"
    echo "IP VPS saat ini: $vps_ip"

    if [[ "$resolved_ip" != "$vps_ip" ]]; then
        echo "⚠️  Domain belum mengarah ke VPS!"
        read -p "Tetap lanjutkan? (y/n): " yn
        [[ "$yn" != "y" ]] && exit 1
    fi

    uuid=$(cat /proc/sys/kernel/random/uuid)

    mkdir -p "$(dirname "$V2RAY_CONFIG")"
    cat > "$V2RAY_CONFIG" << EOF
{
  "inbounds": [{
    "port": 10000,
    "listen": "127.0.0.1",
    "protocol": "vmess",
    "settings": {
      "clients": [{
        "id": "$uuid",
        "alterId": 0,
        "email": "admin@v2ray"
      }]
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "/ws"
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  }]
}
EOF

    # Setup Nginx untuk HTTP (sementara)
    mkdir -p "$(dirname "$NGINX_CONFIG")"
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    cat > "$NGINX_CONFIG" << EOF
server {
    listen 80;
    server_name $domain;
    location /ws {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

    ln -sf "$NGINX_CONFIG" /etc/nginx/sites-enabled/v2ray
    rm -f /etc/nginx/sites-enabled/default
    systemctl restart nginx

    # Dapatkan sertifikat SSL
    echo "Mendapatkan sertifikat SSL untuk domain $domain..."
    if ! certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$email"; then
        echo "❌ Gagal mendapatkan sertifikat SSL"
        exit 1
    fi

    # Konfigurasi HTTPS
    cat > "$NGINX_CONFIG" << EOF
server {
    listen 443 ssl;
    server_name $domain;
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location /ws {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}

server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}
EOF

    systemctl restart nginx
    systemctl enable --now v2ray

    echo -e "\n✅ Instalasi selesai!"
    show_config "$uuid" "admin@v2ray"
}

# Tampilkan konfigurasi client
show_config() {
    local uuid=$1
    local email=$2
    local domain
    
    if [ -f "$NGINX_CONFIG" ]; then
        domain=$(grep -m1 "server_name" "$NGINX_CONFIG" | awk '{print $2}' | tr -d ';')
    else
        domain="your-domain.com"
    fi
    
    echo -e "\n🔐 Config untuk user: $email"
    echo "Domain : $domain"
    echo "UUID   : $uuid"
    echo "Path   : /ws"
    echo "Port   : 443"

    local vmess_config=$(cat <<EOF
{
  "v": "2",
  "ps": "v2ray-$email",
  "add": "$domain",
  "port": "443",
  "id": "$uuid",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "$domain",
  "path": "/ws",
  "tls": "tls"
}
EOF
)
    local link=$(echo -n "$vmess_config" | base64 -w 0)
    echo -e "\nvmess://$link"
}

# Tambah user baru
add_user() {
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    read -p "Masukkan email/nama user baru: " email

    if [ ! -f "$V2RAY_CONFIG" ]; then
        echo "❌ File konfigurasi tidak ditemukan!"
        exit 1
    fi

    cp "$V2RAY_CONFIG" "$V2RAY_CONFIG.bak"
    if ! jq --arg uuid "$uuid" --arg email "$email" \
      '.inbounds[0].settings.clients += [{"id":$uuid,"alterId":0,"email":$email}]' \
      "$V2RAY_CONFIG.bak" > "$V2RAY_CONFIG"; then
        echo "❌ Gagal menambah user"
        mv "$V2RAY_CONFIG.bak" "$V2RAY_CONFIG"
        exit 1
    fi

    systemctl restart v2ray
    echo -e "\n✅ User berhasil ditambahkan!"
    show_config "$uuid" "$email"
}

# Hapus user
delete_user() {
    if [ ! -f "$V2RAY_CONFIG" ]; then
        echo "❌ File konfigurasi tidak ditemukan!"
        exit 1
    fi

    echo "Daftar user:"
    jq -r '.inbounds[0].settings.clients[] | "\(.email) - \(.id)"' "$V2RAY_CONFIG"
    
    read -p "Masukkan email/UUID user yang akan dihapus: " target
    
    cp "$V2RAY_CONFIG" "$V2RAY_CONFIG.bak"
    if [[ "$target" == *"@"* ]]; then
        if ! jq --arg email "$target" \
          'del(.inbounds[0].settings.clients[] | select(.email == $email))' \
          "$V2RAY_CONFIG.bak" > "$V2RAY_CONFIG"; then
            echo "❌ Gagal menghapus user"
            mv "$V2RAY_CONFIG.bak" "$V2RAY_CONFIG"
            exit 1
        fi
    else
        if ! jq --arg uuid "$target" \
          'del(.inbounds[0].settings.clients[] | select(.id == $uuid))' \
          "$V2RAY_CONFIG.bak" > "$V2RAY_CONFIG"; then
            echo "❌ Gagal menghapus user"
            mv "$V2RAY_CONFIG.bak" "$V2RAY_CONFIG"
            exit 1
        fi
    fi
    
    systemctl restart v2ray
    echo "✅ User berhasil dihapus!"
}

# Fungsi menu utama
main_menu() {
    echo -e "\n=== V2Ray Manager ==="
    echo "1) Install V2Ray + Buat User Awal"
    echo "2) Tambah User Baru"
    echo "3) Hapus User"
    echo "4) Tampilkan Daftar User"
    echo "5) Keluar"
    
    read -p "Pilih menu [1-5]: " choice
    case "$choice" in
        1) initial_setup ;;
        2) add_user ;;
        3) delete_user ;;
        4) 
            if [ -f "$V2RAY_CONFIG" ]; then
                echo "Daftar user:"
                jq -r '.inbounds[0].settings.clients[] | "\(.email) - \(.id)"' "$V2RAY_CONFIG"
            else
                echo "❌ V2Ray belum terinstall"
            fi
            ;;
        5) exit 0 ;;
        *) echo "Pilihan tidak valid"; main_menu ;;
    esac
}

# Cek root
if [[ $EUID -ne 0 ]]; then
    echo "Script ini harus dijalankan sebagai root." >&2
    exit 1
fi

# Jalankan menu jika script sudah jadi perintah 'start'
if [[ "$(realpath "$0")" == "$INSTALL_PATH" ]]; then
    main_menu
else
    # Install script dari GitHub ke /usr/local/bin/start
    echo "Menginstall script ke $INSTALL_PATH..."
    wget -qO "$INSTALL_PATH" https://raw.githubusercontent.com/Septahadif/vmess/main/v2ray-manager.sh
    chmod +x "$INSTALL_PATH"

    echo -e "\n✅ Instalasi selesai."
    echo "Jalankan manajer dengan perintah: start"
fi
