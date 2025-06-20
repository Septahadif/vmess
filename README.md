# 📡 V2Ray Installer & Manager (Auto Setup)

Script otomatis untuk menginstal, mengkonfigurasi, dan mengelola V2Ray dengan WebSocket + TLS di VPS Ubuntu/Debian.

## ✅ Fitur

- Otomatis instal V2Ray dan NGINX
- Otomatis deteksi domain dan pasang sertifikat SSL (Let's Encrypt)
- Manajemen user:
  - Tambah user
  - Hapus user
  - Tampilkan daftar user
- Link `vmess://` langsung jadi
- Hanya butuh 1 perintah untuk mulai

## 🖥️ Cara Instalasi

> VPS harus sudah memiliki domain yang diarahkan ke IP server!

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Septahadif/vmess/main/v2ray-manager.sh)
