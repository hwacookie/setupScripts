#!/bin/bash
set -euo pipefail

# Standard-Endpoint
DEFAULT_ENDPOINT="u7kbhjk38mjye00o.myfritz.net"
API_PORT="8050"

# ---------------------------------------------------------
# FEHLER-HANDLING / HELPER
# ---------------------------------------------------------

error_exit() {
  echo ""
  echo "=================================================="
  echo " FEHLER: $1"
  echo "=================================================="
  if [ -n "${2:-}" ]; then
    echo "Mögliche Ursachen & Lösungsschritte:"
    echo "$2"
  fi
  echo "=================================================="
  exit 1
}

# 1. OS-Erkennung (macOS vs. Linux)
OS_TYPE="$(uname -s)"

if [ "${OS_TYPE}" = "Linux" ]; then
  if [ "$EUID" -ne 0 ]; then
    error_exit "Dieses Skript muss auf Linux mit 'sudo' ausgeführt werden!" \
               "  -> Aufruf: sudo ./setup_client.sh"
  fi
elif [ "${OS_TYPE}" = "Darwin" ]; then
  echo "--> macOS erkannt."
else
  error_exit "Nicht unterstütztes Betriebssystem: ${OS_TYPE}"
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
  error_exit "API_TOKEN ist nicht gesetzt!" \
             "  1) Interaktiv eingeben beim Starten\n  2) Als Variable übergeben: sudo API_TOKEN=\"...\" ./setup_client.sh"
fi

# ---------------------------------------------------------
# DEPENDENCIES INSTALLIEREN & ORDNER EINRICHTEN
# ---------------------------------------------------------

if [ "${OS_TYPE}" = "Linux" ]; then
  if ! command -v wg &> /dev/null || ! command -v jq &> /dev/null; then
    echo "--> Installiere WireGuard & Tools via apt..."
    apt-get update -qq && apt-get install -y -qq wireguard wireguard-tools curl jq ufw || \
      error_exit "Paketinstallation über apt-get fehlgeschlagen." "Prüfe deine Internetverbindung auf dem Client."
  fi
  WG_DIR="/etc/wireguard"
elif [ "${OS_TYPE}" = "Darwin" ]; then
  if ! command -v wg &> /dev/null || ! command -v jq &> /dev/null; then
    echo "--> Installiere wireguard-tools & jq via Homebrew..."
    brew install wireguard-tools jq curl || \
      error_exit "Homebrew-Installation fehlgeschlagen." "Stelle sicher, dass Homebrew auf deinem Mac installiert ist."
  fi
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
  sudo chmod 600 "${KEY_DIR}/private.key" "${KEY_DIR}/public.key"
fi

CLIENT_PRIV=$(sudo cat "${KEY_DIR}/private.key")
CLIENT_PUB=$(sudo cat "${KEY_DIR}/public.key")

echo "--> Registriere Client bei ${SERVER_ENDPOINT}:${API_PORT}..."

# HTTP Statuscode & Response getrennt auslesen, Timeout auf 5 Sekunden
HTTP_STATUS=$(curl -s -o /tmp/wg_api_res.txt -w "%{http_code}" --connect-timeout 5 \
  -X POST "http://${SERVER_ENDPOINT}:${API_PORT}/register" \
  -H "X-API-Token: ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"pubkey\": \"${CLIENT_PUB}\"}" || echo "000")

RESPONSE=$(cat /tmp/wg_api_res.txt 2>/dev/null || echo "")

# ---------------------------------------------------------
# HTTP RESPONSE PRÜFEN
# ---------------------------------------------------------

if [ "${HTTP_STATUS}" = "000" ]; then
  error_exit "Verbindung zum Server '${SERVER_ENDPOINT}:${API_PORT}' fehlgeschlagen (Timeout/Refused)!" \
             "  1. Ist Port 8050 TCP in der Fritz!Box freigegeben?\n  2. Läuft der API-Dienst auf home-gateway? (sudo systemctl status wg-api)\n  3. Teste Erreichbarkeit im Mac-Terminal: nc -zv ${SERVER_ENDPOINT} 8050"

elif [ "${HTTP_STATUS}" = "401" ]; then
  error_exit "401 Unauthorized - Ungültiges API-Token!" \
             "  Das angegebene API-Token stimmt nicht mit der Datei /etc/wireguard/keys/api_token.txt auf dem Server überein."

elif [ "${HTTP_STATUS}" -ne 200 ]; then
  error_exit "Server meldet Fehler (HTTP Status ${HTTP_STATUS})!" \
             "  Antwort vom Server: ${RESPONSE}"
fi

ASSIGNED_IP=$(echo "${RESPONSE}" | jq -r '.ip // empty')
SERVER_PUBKEY=$(echo "${RESPONSE}" | jq -r '.server_pubkey // empty')

if [ -z "${ASSIGNED_IP}" ] || [ -z "${SERVER_PUBKEY}" ]; then
  error_exit "Server-Antwort war unvollständig oder ungültig!" \
             "  Rohdaten der Antwort: ${RESPONSE}"
fi

echo "--> Vom Server zugewiesene VPN-IP: ${ASSIGNED_IP}"

# ---------------------------------------------------------
# CONFIG SCHREIBEN & TUNNEL STARTEN (Ohne DNS-Verbiegung)
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
  systemctl enable --now wg-quick@wg0 || error_exit "Konnte wg-quick@wg0 nicht starten."

  # Firewall auf Linux
  ufw default deny incoming 2>/dev/null || true
  ufw default allow outgoing 2>/dev/null || true
  ufw allow 22/tcp 2>/dev/null || true
  ufw allow in on wg0 2>/dev/null || true
  ufw --force enable 2>/dev/null || true

elif [ "${OS_TYPE}" = "Darwin" ]; then
  echo "--> Starte WireGuard Tunnel auf macOS..."
  sudo wg-quick down wg0 2>/dev/null || true
  sudo wg-quick up wg0 || error_exit "Konnte WireGuard Tunnel auf macOS nicht aktivieren."
fi

echo "=================================================="
echo " CLIENT ERFOLGREICH VERBUNDEN!"
echo " OS:            ${OS_TYPE}"
echo " VPN IP:        ${ASSIGNED_IP}"
echo " Config Pfad:   ${CONF_FILE}"
echo "=================================================="
echo ""

# ---------------------------------------------------------
# ALLE REGISTRIERTEN CLIENTS VOM SERVER ABFRAGEN
# ---------------------------------------------------------

echo "--> Hole Liste aller registrierten VPN-Clients..."
CLIENTS_RESPONSE=$(curl -s --connect-timeout 3 -X GET "http://${SERVER_ENDPOINT}:${API_PORT}/clients" \
  -H "X-API-Token: ${API_TOKEN}" || echo "")

if [ -n "${CLIENTS_RESPONSE}" ] && echo "${CLIENTS_RESPONSE}" | jq -e '.clients' >/dev/null 2>&1; then
  echo "=================================================="
  echo " REGISTRIERTE GERÄTE IM VPN"
  echo "=================================================="
  printf "%-12s | %-8s | %-24s | %s\n" "VPN IP" "STATUS" "ENDPOINT" "PUBLIC KEY"
  echo "--------------------------------------------------------------------------------"
  
  echo "${CLIENTS_RESPONSE}" | jq -r '.clients[] | "\(.ip)\t\(if .is_online then "ONLINE" else "OFFLINE" end)\t\(.endpoint // "Keine Verbdg.")\t\(.pubkey)"' | \
  while IFS=$'\t' read -r ip status endpoint pubkey; do
    printf "%-12s | %-8s | %-24s | %s\n" "${ip}" "${status}" "${endpoint}" "${pubkey:0:15}..."
  done
  echo "=================================================="
else
  echo "(Hinweis: Client-Liste konnte nach dem Verbinden nicht abgerufen werden)"
fi
