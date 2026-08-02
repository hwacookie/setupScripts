#!/bin/bash
set -euo pipefail

# 1. Root-Check
if [ "$EUID" -ne 0 ]; then
  echo "Fehler: Bitte führe das Skript mit 'sudo' aus!"
  exit 1
fi

# Variablen aus Argumenten $1 / $2 ODER Umgebungsvariablen ODER Default auslesen
SERVER_ENDPOINT="${1:-${SERVER_ENDPOINT:-u7kbhjk38mjye00o.myfritz.net}}"
API_TOKEN="${2:-${API_TOKEN:-}}"
API_PORT="8050"

if [ -z "${API_TOKEN}" ]; then
  echo "Fehler: API_TOKEN ist nicht gesetzt!"
  echo ""
  echo "Aufruf-Möglichkeiten:"
  echo "  1) sudo ./setup_client.sh <ENDPOINT> <API_TOKEN>"
  echo "     Beispiel: sudo ./setup_client.sh u7kbhjk38mjye00o.myfritz.net MEIN_TOKEN"
  echo ""
  echo "  2) Als Umgebungsvariable:"
  echo "     sudo API_TOKEN=\"MEIN_TOKEN\" ./setup_client.sh"
  exit 1
fi

# 2. WireGuard & Tools installieren
if ! command -v wg &> /dev/null; then
  echo "--> Installiere WireGuard & Tools..."
  apt-get update && apt-get install -y wireguard wireguard-tools curl jq ufw
fi

KEY_DIR="/etc/wireguard/keys"
mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

# 3. Client Key erzeugen
if [ ! -f "${KEY_DIR}/private.key" ]; then
  echo "--> Generiere einzigartiges Schlüsselpaar für diesen Client..."
  wg genkey | tee "${KEY_DIR}/private.key" | wg pubkey > "${KEY_DIR}/public.key"
  chmod 600 "${KEY_DIR}"/*
fi

CLIENT_PRIV=$(cat "${KEY_DIR}/private.key")
CLIENT_PUB=$(cat "${KEY_DIR}/public.key")

# 4. Registrieren
echo "--> Registriere Client beim Server (${SERVER_ENDPOINT}:${API_PORT})..."
RESPONSE=$(curl -s -X POST "http://${SERVER_ENDPOINT}:${API_PORT}/register" \
  -H "X-API-Token: ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"pubkey\": \"${CLIENT_PUB}\"}")

ASSIGNED_IP=$(echo "${RESPONSE}" | jq -r '.ip // empty')
SERVER_PUBKEY=$(echo "${RESPONSE}" | jq -r '.server_pubkey // empty')

if [ -z "${ASSIGNED_IP}" ]; then
  echo "Fehler bei der Registrierung am Server! Antwort war:"
  echo "${RESPONSE}"
  exit 1
fi

echo "--> Zugewiesene VPN-IP: ${ASSIGNED_IP}"

# 5. Local wg0.conf schreiben
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

# 6. Service starten
systemctl enable --now wg-quick@wg0

# 7. Local Firewall
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow in on wg0
ufw --force enable

echo "=================================================="
echo " CLIENT ERFOLGREICH VERBUNDEN!"
echo " VPN IP dieses Geräts: ${ASSIGNED_IP}"
echo "=================================================="