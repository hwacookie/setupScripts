#!/bin/bash
set -e

# =========================================================
# KONFIGURATION (Hier deine Server-Daten eintragen):
# =========================================================
SERVER_ENDPOINT="u7kbhjk38mjye00o.myfritz.net"
API_PORT="8050"
API_TOKEN="<DEIN_API_TOKEN_VOM_SERVER>"
# =========================================================

# 1. Root-Check
if [ "$EUID" -ne 0 ]; then
  echo "Fehler: Bitte führe das Skript mit 'sudo' aus!"
  exit 1
fi

if [ "${SERVER_ENDPOINT}" == "<DEINE_PUBLIC_IP_ODER_DYNDNS>" ] || [ "${API_TOKEN}" == "<DEIN_API_TOKEN_VOM_SERVER>" ]; then
  echo "Fehler: Bitte trage zuerst deine SERVER_ENDPOINT und deinen API_TOKEN im Skript ein!"
  exit 1
fi

# 2. WireGuard & Tools installieren
if ! command -v wg &> /dev/null; then
  echo "--> Installiere WireGuard & Werkzeuge..."
  apt-get update && apt-get install -y wireguard wireguard-tools curl jq ufw
fi

KEY_DIR="/etc/wireguard/keys"
mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

# 3. Schlüsselpaar lokal erzeugen
if [ ! -f "${KEY_DIR}/private.key" ]; then
  echo "--> Generiere einzigartiges Schlüsselpaar für diesen Client..."
  wg genkey | tee "${KEY_DIR}/private.key" | wg pubkey > "${KEY_DIR}/public.key"
  chmod 600 "${KEY_DIR}"/*
fi

CLIENT_PRIV=$(cat "${KEY_DIR}/private.key")
CLIENT_PUB=$(cat "${KEY_DIR}/public.key")

# 4. Beim Server registrieren & IP abfragen
echo "--> Registriere Client beim Server (${SERVER_ENDPOINT}:${API_PORT})..."
RESPONSE=$(curl -s -X POST "http://${SERVER_ENDPOINT}:${API_PORT}/register" \
  -H "X-API-Token: ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"pubkey\": \"${CLIENT_PUB}\"}")

ASSIGNED_IP=$(echo "${RESPONSE}" | jq -r '.ip')
SERVER_PUBKEY=$(echo "${RESPONSE}" | jq -r '.server_pubkey')

if [ -z "${ASSIGNED_IP}" ] || [ "${ASSIGNED_IP}" == "null" ]; then
  echo "Fehler bei der Registrierung am Server! Antwort vom Server war:"
  echo "${RESPONSE}"
  exit 1
fi

echo "--> Vom Server zugewiesene VPN-IP: ${ASSIGNED_IP}"

# 5. Local wg0.conf erstellen
cat << EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${ASSIGNED_IP}/32

[Peer]
PublicKey = ${SERVER_PUBKEY}
Endpoint = ${SERVER_ENDPOINT}:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/wg0.conf

# 6. Service aktivieren & starten
systemctl enable --now wg-quick@wg0

# 7. Local Firewall konfigurieren
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow in on wg0
ufw --force enable

echo "=================================================="
echo " CLIENT ERFOLGREICH VERBUNDEN!"
echo " VPN IP dieses Geräts: ${ASSIGNED_IP}"
echo "=================================================="
