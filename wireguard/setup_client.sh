#!/bin/bash
set -euo pipefail

# Standard-Endpoint
DEFAULT_ENDPOINT="u7kbhjk38mjye00o.myfritz.net"
API_PORT="8050"

# 1. OS-Erkennung (macOS vs. Linux)
OS_TYPE="$(uname -s)"

if [ "${OS_TYPE}" = "Linux" ]; then
  if [ "$EUID" -ne 0 ]; then
    echo "Fehler: Auf Linux bitte das Skript mit 'sudo' ausführen!"
    exit 1
  fi
elif [ "${OS_TYPE}" = "Darwin" ]; then
  echo "--> macOS erkannt."
else
  echo "Fehler: Nicht unterstütztes Betriebssystem: ${OS_TYPE}"
  exit 1
fi

# ---------------------------------------------------------
# INTERAKTIVE ODER ENV-BASIERTE ABFRAGE
# ---------------------------------------------------------

SERVER_ENDPOINT="${1:-${SERVER_ENDPOINT:-}}"
if [ -z "${SERVER_ENDPOINT}" ]; then
  if [ -t 0 ]; then
    read -p "Server Endpoint/DynDNS [Default: ${DEFAULT_ENDPOINT}]: " INPUT_ENDPOINT
    SERVER_ENDPOINT="${INPUT_ENDPOINT:-${DEFAULT_ENDPOINT}}"
  else
    SERVER_ENDPOINT="${DEFAULT_ENDPOINT}"
  fi
fi

API_TOKEN="${2:-${API_TOKEN:-}}"
if [ -z "${API_TOKEN}" ]; then
  if [ -t 0 ]; then
    echo -n "API Token eingeben: "
    read -s API_TOKEN
    echo ""
  fi
fi

if [ -z "${API_TOKEN}" ]; then
  echo "Fehler: API_TOKEN ist nicht gesetzt!"
  exit 1
fi

# ---------------------------------------------------------
# DEPENDENCIES INSTALLIEREN & ORDNER EINRICHTEN
# ---------------------------------------------------------

if [ "${OS_TYPE}" = "Linux" ]; then
  if ! command -v wg &> /dev/null; then
    echo "--> Installiere WireGuard & Tools via apt..."
    apt-get update && apt-get install -y wireguard wireguard-tools curl jq ufw
  fi
  WG_DIR="/etc/wireguard"
elif [ "${OS_TYPE}" = "Darwin" ]; then
  if ! command -v wg &> /dev/null || ! command -v jq &> /dev/null; then
    echo "--> Installiere wireguard-tools & jq via Homebrew..."
    brew install wireguard-tools jq curl
  fi
  
  # Pfad für Homebrew WireGuard-Configs (Intel vs Apple Silicon)
  BREW_PREFIX="$(brew --prefix)"
  WG_DIR="${BREW_PREFIX}/etc/wireguard"
  sudo mkdir -p "${WG_DIR}"
fi

KEY_DIR="${WG_DIR}/keys"
sudo mkdir -p "${KEY_DIR}"
sudo chmod 700 "${KEY_DIR}"

# ---------------------------------------------------------
# KEY GENERIERUNG & REGISTRIERUNG
# ---------------------------------------------------------

if [ ! -f "${KEY_DIR}/private.key" ]; then
  echo "--> Generiere einzigartiges Schlüsselpaar für diesen Client..."
  PRIV_KEY=$(wg genkey)
  PUB_KEY=$(echo "${PRIV_KEY}" | wg pubkey)
  
  echo "${PRIV_KEY}" | sudo tee "${KEY_DIR}/private.key" > /dev/null
  echo "${PUB_KEY}" | sudo tee "${KEY_DIR}/public.key" > /dev/null
  sudo chmod 600 "${KEY_DIR}"/*
fi

CLIENT_PRIV=$(sudo cat "${KEY_DIR}/private.key")
CLIENT_PUB=$(sudo cat "${KEY_DIR}/public.key")

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

echo "--> Vom Server zugewiesene VPN-IP: ${ASSIGNED_IP}"

# ---------------------------------------------------------
# CONFIG SCHREIBEN & TUNNEL STARTEN
# ---------------------------------------------------------

CONF_FILE="${WG_DIR}/wg0.conf"

cat << EOF | sudo tee "${CONF_FILE}" > /dev/null
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${ASSIGNED_IP}/32

[Peer]
PublicKey = ${SERVER_PUBKEY}
Endpoint = ${SERVER_ENDPOINT}:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
EOF

sudo chmod 600 "${CONF_FILE}"

if [ "${OS_TYPE}" = "Linux" ]; then
  echo "--> Starte WireGuard Service (systemd)..."
  systemctl enable --now wg-quick@wg0

  # Firewall auf Linux
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow in on wg0
  ufw --force enable

elif [ "${OS_TYPE}" = "Darwin" ]; then
  echo "--> Starte WireGuard Tunnel auf macOS..."
  # Falls wg0 bereits läuft, erst stoppen
  sudo wg-quick down wg0 2>/dev/null || true
  sudo wg-quick up wg0
fi

echo "=================================================="
echo " CLIENT ERFOLGREICH VERBUNDEN!"
echo " OS:            ${OS_TYPE}"
echo " VPN IP:        ${ASSIGNED_IP}"
echo " Config Pfad:   ${CONF_FILE}"
echo "=================================================="