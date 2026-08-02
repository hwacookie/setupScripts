#!/bin/bash
set -euo pipefail

# 1. Root-Check
if [ "$EUID" -ne 0 ]; then
  echo "Fehler: Bitte führe das Skript mit 'sudo' aus!"
  exit 1
fi

# Standard-Endpoint definieren
DEFAULT_ENDPOINT="u7kbhjk38mjye00o.myfritz.net"

# ---------------------------------------------------------
# INTERAKTIVE ODER ENV-BASIERTE ABFRAGE
# ---------------------------------------------------------

# Server Endpoint ermitteln ($1 Argument -> $SERVER_ENDPOINT Env -> Default)
SERVER_ENDPOINT="${1:-${SERVER_ENDPOINT:-}}"
if [ -z "${SERVER_ENDPOINT}" ]; then
  # Interaktiv nachfragen, wenn Terminal vorhanden
  if [ -t 0 ]; then
    read -p "Server Endpoint/DynDNS [Default: ${DEFAULT_ENDPOINT}]: " INPUT_ENDPOINT
    SERVER_ENDPOINT="${INPUT_ENDPOINT:-${DEFAULT_ENDPOINT}}"
  else
    SERVER_ENDPOINT="${DEFAULT_ENDPOINT}"
  fi
fi

# API Token ermitteln ($2 Argument -> $API_TOKEN Env -> Interaktiv)
API_TOKEN="${2:-${API_TOKEN:-}}"
if [ -z "${API_TOKEN}" ]; then
  # Interaktiv nachfragen (Eingabe maskiert mit read -s)
  if [ -t 0 ]; then
    echo -n "API Token eingeben: "
    read -s API_TOKEN
    echo ""
  fi
fi

# Prüfen, ob wir jetzt ein Token haben
if [ -z "${API_TOKEN}" ]; then
  echo "Fehler: API_TOKEN ist nicht gesetzt und konnte nicht erfragt werden!"
  echo "Nutzung: sudo API_TOKEN=\"...\" ./setup_client.sh"
  exit 1
fi

API_PORT="8050"

# ---------------------------------------------------------
# SETUP & REGISTRIERUNG
# ---------------------------------------------------------

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
echo "--> Registriere Client bei ${SERVER_ENDPOINT}:${API_PORT}..."
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