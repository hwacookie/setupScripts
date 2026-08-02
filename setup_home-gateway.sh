#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Fehler: Bitte führe das Skript mit 'sudo' aus!"
  exit 1
fi

echo "=== 1. Installiere WireGuard auf home-gateway ==="
apt-get update && apt-get install -y wireguard wireguard-tools ufw iptables

KEY_DIR="/etc/wireguard/keys"
mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

echo "=== 2. Generiere Schlüssel für Server, Mac und Verda ==="
# Server Key
if [ ! -f "${KEY_DIR}/server_private.key" ]; then
  wg genkey | tee "${KEY_DIR}/server_private.key" | wg pubkey > "${KEY_DIR}/server_public.key"
  
  # Mac Client Key
  wg genkey | tee "${KEY_DIR}/mac_private.key" | wg pubkey > "${KEY_DIR}/mac_public.key"
  
  # Verda Client Key
  wg genkey | tee "${KEY_DIR}/verda_private.key" | wg pubkey > "${KEY_DIR}/verda_public.key"
  
  chmod 600 ${KEY_DIR}/*
fi

SERVER_PRIV=$(cat "${KEY_DIR}/server_private.key")
SERVER_PUB=$(cat "${KEY_DIR}/server_public.key")

MAC_PRIV=$(cat "${KEY_DIR}/mac_private.key")
MAC_PUB=$(cat "${KEY_DIR}/mac_public.key")

VERDA_PRIV=$(cat "${KEY_DIR}/verda_private.key")
VERDA_PUB=$(cat "${KEY_DIR}/verda_public.key")

DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

echo "=== 3. Erstelle WireGuard Server-Konfiguration (/etc/wireguard/wg0.conf) ==="
cat << EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = ${SERVER_PRIV}
Address = 10.8.0.1/24
ListenPort = 51820
# Erlaubt das Routing zwischen den WireGuard-Clients (Mac <-> Verda)
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE

[Peer]
# Client 1: Dein Mac
PublicKey = ${MAC_PUB}
AllowedIPs = 10.8.0.2/32

[Peer]
# Client 2: Verda-Instanzen
PublicKey = ${VERDA_PUB}
AllowedIPs = 10.8.0.100/32
EOF

chmod 600 /etc/wireguard/wg0.conf

# IP-Forwarding im Kernel aktivieren
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf || true

echo "=== 4. Starte WireGuard Dienst ==="
systemctl enable --now wg-quick@wg0

echo "=== 5. erstelle Client-Dateien ==="

# Public IP oder DynDNS deines Heimnetzes ermitteln
PUBLIC_ENDPOINT=$(curl -s ifconfig.me || curl -s api.ipify.org)

# A) Config für Mac
cat << EOF > "${KEY_DIR}/mac.conf"
[Interface]
PrivateKey = ${MAC_PRIV}
Address = 10.8.0.2/32

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${PUBLIC_ENDPOINT}:51820
# 10.8.0.0/24 leitet allen Traffic für das VPN (inkl. Verda unter 10.8.0.100) durch den Tunnel
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
EOF

# B) Config für Verda (wird im Verda Startup-Skript verwendet)
cat << EOF > "${KEY_DIR}/verda.conf"
[Interface]
PrivateKey = ${VERDA_PRIV}
Address = 10.8.0.100/32

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${PUBLIC_ENDPOINT}:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
EOF

# UFW Firewall auf home-gateway anpassen
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 51820/udp
ufw allow in on wg0
ufw --force enable

echo "=================================================="
echo " Setup auf home-gateway abgeschlossen!"
echo " Mac Config:   ${KEY_DIR}/mac.conf"
echo " Verda Config: ${KEY_DIR}/verda.conf"
echo "=================================================="
