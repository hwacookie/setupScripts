#!/bin/bash
set -e

# 1. Prüfen auf Root / Sudo-Rechte
if [ "$EUID" -ne 0 ]; then
  echo "Fehler: Bitte führe das Skript mit 'sudo' aus!"
  exit 1
fi

# 2. VORAB-CHECK: Ist WireGuard installiert? Wenn nicht -> direkt installieren!
if ! command -v wg &> /dev/null; then
  echo "--> WireGuard nicht gefunden. Installiere wireguard & wireguard-tools..."
  apt-get update && apt-get install -y wireguard wireguard-tools qrencode ufw
fi

# 3. Hostname-Handling (Optionales Argument $1)
if [ -n "$1" ]; then
  CUSTOM_HOST="$1"
  echo "--> Setze neuen Hostnamen auf: '${CUSTOM_HOST}'..."
  
  # System-Hostname setzen
  hostnamectl set-hostname "${CUSTOM_HOST}"
  
  # /etc/hosts aktualisieren
  sed -i "s/127.0.1.1.*/127.0.1.1 ${CUSTOM_HOST}/g" /etc/hosts || true
  
  # Cloud-Init konfigurieren (verhindert Zurücksetzen beim Reboot)
  if [ -f /etc/cloud/cloud.cfg ]; then
    sed -i 's/preserve_hostname: false/preserve_hostname: true/g' /etc/cloud/cloud.cfg
  fi
fi

# Dynamische Variablen auslesen
HOST_NAME=$(hostname)
PUBLIC_IP=$(curl -s ifconfig.me || curl -s api.ipify.org)
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

echo "=================================================="
echo " WireGuard Setup für Host: ${HOST_NAME}"
echo " Öffentliche IP:            ${PUBLIC_IP}"
echo " Primäre Schnittstelle:    ${DEFAULT_IFACE}"
echo "=================================================="

# 4. Schlüsselverzeichnis pro Host anlegen
KEY_DIR="/etc/wireguard/keys_${HOST_NAME}"
mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

if [ ! -f "${KEY_DIR}/server_private.key" ]; then
  echo "--> Generiere neues Schlüsselpaar für Server und Mac..."
  wg genkey | tee "${KEY_DIR}/server_private.key" | wg pubkey > "${KEY_DIR}/server_public.key"
  wg genkey | tee "${KEY_DIR}/mac_private.key" | wg pubkey > "${KEY_DIR}/mac_public.key"
  chmod 600 ${KEY_DIR}/*
fi

SERVER_PRIV=$(cat "${KEY_DIR}/server_private.key")
SERVER_PUB=$(cat "${KEY_DIR}/server_public.key")
MAC_PRIV=$(cat "${KEY_DIR}/mac_private.key")
MAC_PUB=$(cat "${KEY_DIR}/mac_public.key")

# 5. Server-Konfiguration (/etc/wireguard/wg0.conf)
echo "--> Schreibe Server-Konfiguration (/etc/wireguard/wg0.conf)..."
cat << EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = ${SERVER_PRIV}
Address = 10.8.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE

[Peer]
# Mac Client
PublicKey = ${MAC_PUB}
AllowedIPs = 10.8.0.2/32
EOF

chmod 600 /etc/wireguard/wg0.conf

# 6. WireGuard-Dienst starten
echo "--> Starte WireGuard-Dienst..."
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# 7. Firewall (UFW)
echo "--> Konfiguriere UFW Firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp        # SSH öffentlich
ufw allow 51820/udp     # WireGuard VPN Port
ufw allow in on wg0     # Alle internen Tunnel-Anfragen erlauben
ufw --force enable

# 8. Mac-Client-Konfiguration
CLIENT_CONF_PATH="${KEY_DIR}/${HOST_NAME}-mac.conf"
cat << EOF > "${CLIENT_CONF_PATH}"
[Interface]
PrivateKey = ${MAC_PRIV}
Address = 10.8.0.2/32

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${PUBLIC_IP}:51820
AllowedIPs = 10.8.0.1/32
PersistentKeepalive = 25
EOF

echo "=================================================="
echo " Setup erfolgreich abgeschlossen!"
echo " Client-Konfiguration abgespeichert unter:"
echo " ${CLIENT_CONF_PATH}"
echo "=================================================="
echo ""
echo "--- Inhalts-Vorschau für den Mac WireGuard-Import ---"
cat "${CLIENT_CONF_PATH}"