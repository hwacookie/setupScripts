#!/bin/bash

# Stellen sicher, dass WireGuard installiert ist
if ! command -v wg &> /dev/null; then
  echo "Installing WireGuard..."
  apt-get update && apt-get install -y wireguard wireguard-tools
fi

# 1. Schlüsselpaar für den Server & den Mac generieren
mkdir -p /etc/wireguard/keys
chmod 700 /etc/wireguard/keys

wg genkey | tee /etc/wireguard/keys/server_private.key | wg pubkey > /etc/wireguard/keys/server_public.key
wg genkey | tee /etc/wireguard/keys/mac_private.key | wg pubkey > /etc/wireguard/keys/mac_public.key

chmod 600 /etc/wireguard/keys/*

# 2. Server-Konfiguration erstellen
SERVER_PRIV=$(cat /etc/wireguard/keys/server_private.key)
MAC_PUB=$(cat /etc/wireguard/keys/mac_public.key)

cat << EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = ${SERVER_PRIV}
Address = 10.8.0.1/24
ListenPort = 51820

[Peer]
# Dein Mac
PublicKey = ${MAC_PUB}
AllowedIPs = 10.8.0.2/32
EOF

chmod 600 /etc/wireguard/wg0.conf

# 3. WireGuard starten und beim Booten aktivieren
systemctl enable --now wg-quick@wg0
