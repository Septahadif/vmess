#!/bin/bash

set -e

V2RAY_CONFIG="/usr/local/etc/v2ray/config.json"
NGINX_CONFIG="/etc/nginx/sites-available/v2ray"
INSTALL_PATH="/usr/local/bin/start"

# Fungsi untuk install dependensi
install_dependencies() {
    apt update -y
    apt install -y jq curl wget gnupg2 ca-certificates lsb-release nginx certbot python3-certbot-nginx
}

# Fungsi install V2Ray
install_v2ray() {
    curl -O https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh
    bash install-release.sh
}

# Fungsi setup awal
initial_setup() {
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

    mkdir -p "$(dirname $V2RAY_CONFIG)"
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
    mkdir -p "$(dirname $NGINX_CONFIG)"
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
    nginx -t && systemctl reload nginx

    # Dapatkan sertifikat SSL
    certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$email"

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

    nginx -t && systemctl reload nginx
    systemctl enable --now v2ray

    echo -e "\n✅ Instalasi selesai!"
    show_config "$uuid" "admin@v2ray"
}

# Tampilkan konfigurasi client
show_config() {
    local uuid=$1
    local email=$2
    local domain=$(grep -m1 "server_name" "$NGINX_CONFIG" | awk '{print $2}' | tr -d ';')
    
    echo -e "\n🔐 Config untuk user: $email"
    echo "Domain : $domain"
    echo "UUID   : $uuid"
    echo "Path   : /ws"
    echo "Port   : 443"

    local link=$(echo -n '{"v":"2","ps":"v2ray-'$email'","add":"'$domain'","port":"443","id":"'$uuid'","aid":"0","net":"ws","type":"none","host":"'$domain'","path":"/ws","tls":"tls"}' | base64 -w 0)
    echo -e "\nvmess://$link"
}

# Tambah user baru
add_user() {
    install_dependencies

    local uuid=$(cat /proc/sys/kernel/random/uuid)
    read -p "Masukkan email/nama user baru: " email

    if [ ! -f "$V2RAY_CONFIG" ]; then
        echo "❌ File konfigurasi tidak ditemukan!"
        exit 1
    fi

    cp "$V2RAY_CONFIG" "$V2RAY_CONFIG.bak"
    jq --arg uuid "$uuid" --arg email "$email" \
    '.inbounds[0].settings.clients += [{"id":$uuid,"alterId":0,"email":$email}]' \
    "$V2RAY_CONFIG.bak" > "$V2RAY_CONFIG"

    systemctl restart v2ray
    echo -e "\n✅ User berhasil ditambahkan!"
    show_config "$uuid" "$email"
}

# Hapus user
delete_user() {
    install_dependencies

    if [ ! -f "$V2RAY_CONFIG" ]; then
        echo "❌ File konfigurasi tidak ditemukan!"
        exit 1
    fi

    echo "Daftar user:"
    jq -r '.inbounds[0].settings.clients[] | "
