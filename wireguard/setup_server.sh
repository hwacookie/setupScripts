#!/bin/bash
set -euo pipefail

error_exit() {
  echo ""
  echo "=================================================="
  echo " SERVER SETUP FEHLER: $1"
  echo "=================================================="
  exit 1
}

# 1. Root-Check
if [ "$EUID" -ne 0 ]; then
  error_exit "Bitte führe das Skript mit 'sudo' aus!"
fi

echo "=== 1. Installiere System-Pakete ==="
apt-get update -qq && apt-get install -y -qq wireguard wireguard-tools ufw iptables python3 curl jq || \
  error_exit "Apt-Paketinstallation fehlgeschlagen. Prüfe die Paketquellen/Internetverbindung."

KEY_DIR="/etc/wireguard/keys"
mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

# 2. Server Keys & API Token generieren
echo "=== 2. Generiere Server-Schlüssel & API-Token ==="
if [ ! -f "${KEY_DIR}/server_private.key" ]; then
  wg genkey | tee "${KEY_DIR}/server_private.key" | wg pubkey > "${KEY_DIR}/server_public.key" || \
    error_exit "Erzeugung der WireGuard-Schlüssel fehlgeschlagen."
fi

if [ ! -f "${KEY_DIR}/api_token.txt" ]; then
  head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24 > "${KEY_DIR}/api_token.txt" || \
    error_exit "Erzeugung des API-Tokens fehlgeschlagen."
fi

# ---------------------------------------------------------
# PI-HOLE v6 REST API KONFIGURATION (INTERAKTIVE ABFRAGE)
# ---------------------------------------------------------
echo "=== 3. Pi-hole v6 REST API Integration setup ==="

PIHOLE_URL_FILE="${KEY_DIR}/pihole_url.txt"
PIHOLE_TOKEN_FILE="${KEY_DIR}/pihole_token.txt"

# Pi-hole URL abfragen, falls nicht vorhanden
if [ ! -f "${PIHOLE_URL_FILE}" ]; then
  INPUT_URL="${PIHOLE_URL:-}"
  if [ -z "${INPUT_URL}" ] && [ -t 0 ]; then
    read -p "Pi-hole Server URL/IP (z.B. http://192.168.178.10 oder http://ha-prime): " INPUT_URL
  fi
  if [ -n "${INPUT_URL}" ]; then
    echo "${INPUT_URL}" > "${PIHOLE_URL_FILE}"
  else
    echo " (Hinweis: Keine Pi-hole URL angegeben. DNS-Registrierung wird deaktiviert)."
  fi
fi

# Pi-hole Passwort abfragen, falls nicht vorhanden
if [ -f "${PIHOLE_URL_FILE}" ] && [ ! -f "${PIHOLE_TOKEN_FILE}" ]; then
  INPUT_PASS="${PIHOLE_PASSWORD:-}"
  if [ -z "${INPUT_PASS}" ] && [ -t 0 ]; then
    echo -n "Pi-hole Web-Passwort/API-Token eingeben: "
    read -s INPUT_PASS
    echo ""
  fi
  if [ -n "${INPUT_PASS}" ]; then
    echo "${INPUT_PASS}" > "${PIHOLE_TOKEN_FILE}"
  else
    echo " (Hinweis: Kein Passwort angegeben. DNS-Registrierung wird deaktiviert)."
  fi
fi

chmod 600 "${KEY_DIR}"/*

SERVER_PRIV=$(cat "${KEY_DIR}/server_private.key")
SERVER_PUB=$(cat "${KEY_DIR}/server_public.key")
API_TOKEN=$(cat "${KEY_DIR}/api_token.txt")
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

if [ -z "${DEFAULT_IFACE}" ]; then
  error_exit "Kein Standard-Netzwerkinterface (Default Route) gefunden!"
fi

# 4. Server wg0.conf Grundgerüst
echo "=== 4. Erstelle Server WireGuard-Konfiguration ==="
cat << EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = ${SERVER_PRIV}
Address = 10.8.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
EOF

chmod 600 /etc/wireguard/wg0.conf
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf >/dev/null || true

systemctl enable --now wg-quick@wg0 || error_exit "WireGuard-Dienst (wg-quick@wg0) konnte nicht gestartet werden."

# 5. API-Server Python-Datei erstellen
echo "=== 5. Erstelle API-Dienst (/usr/local/bin/wg_register_api.py) ==="
cat << 'PYEOF' > /usr/local/bin/wg_register_api.py
import http.server
import json
import subprocess
import os
import urllib.request
import urllib.parse

API_TOKEN_FILE = "/etc/wireguard/keys/api_token.txt"
PIHOLE_URL_FILE = "/etc/wireguard/keys/pihole_url.txt"
PIHOLE_TOKEN_FILE = "/etc/wireguard/keys/pihole_token.txt"
WG_CONF = "/etc/wireguard/wg0.conf"

def read_file_strip(filepath):
    if os.path.exists(filepath):
        with open(filepath, "r") as f:
            return f.read().strip()
    return None

def sync_wireguard():
    cmd = "wg-quick strip wg0 > /tmp/wg_stripped.conf && wg syncconf wg0 /tmp/wg_stripped.conf"
    subprocess.run(cmd, shell=True, check=True)

# ---------------------------------------------------------
# PI-HOLE v6 REST API CALLS
# ---------------------------------------------------------

def pihole_v6_auth(base_url, password):
    """Authentifiziert sich an der Pi-hole v6 API und liefert eine Session-ID (sid)."""
    try:
        url = f"{base_url.rstrip('/')}/api/auth"
        data = json.dumps({"password": password}).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=4) as res:
            resp_data = json.loads(res.read().decode())
            return resp_data.get("session", {}).get("sid")
    except Exception as e:
        print(f"[Pi-hole API Auth Fehler]: {e}")
        return None

def pihole_add_dns_v6(ip, hostname):
    """Fügt Custom DNS über Pi-hole v6 REST API hinzu."""
    base_url = read_file_strip(PIHOLE_URL_FILE)
    password = read_file_strip(PIHOLE_TOKEN_FILE)
    if not base_url or not password:
        return

    sid = pihole_v6_auth(base_url, password)
    if not sid:
        print("[Pi-hole API]: Authentifizierung fehlgeschlagen, überspringe DNS-Eintrag.")
        return

    try:
        url = f"{base_url.rstrip('/')}/api/config/dns/hosts"
        payload = json.dumps({"ip": ip, "hostname": f"{hostname}.vpn"}).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "sid": sid
        }
        req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=4) as res:
            print(f"[Pi-hole API]: DNS hinzugefügt -> {hostname}.vpn = {ip} (Status {res.status})")
    except Exception as e:
        print(f"[Pi-hole API Add Error]: {e}")

def pihole_remove_dns_v6(ip):
    """Entfernt Custom DNS über Pi-hole v6 REST API."""
    base_url = read_file_strip(PIHOLE_URL_FILE)
    password = read_file_strip(PIHOLE_TOKEN_FILE)
    if not base_url or not password:
        return

    sid = pihole_v6_auth(base_url, password)
    if not sid:
        return

    try:
        url = f"{base_url.rstrip('/')}/api/config/dns/hosts/{urllib.parse.quote(ip)}"
        headers = {"sid": sid}
        req = urllib.request.Request(url, headers=headers, method="DELETE")
        with urllib.request.urlopen(req, timeout=4) as res:
            print(f"[Pi-hole API]: DNS entfernt für IP {ip} (Status {res.status})")
    except Exception as e:
        print(f"[Pi-hole API Remove Error]: {e}")


# ---------------------------------------------------------
# HTTP SERVER HANDLER
# ---------------------------------------------------------

class RegisterHandler(http.server.BaseHTTPRequestHandler):
    def check_auth(self):
        token = self.headers.get("X-API-Token")
        valid_token = read_file_strip(API_TOKEN_FILE)
        if not valid_token or token != valid_token:
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"401 Unauthorized")
            return False
        return True

    def do_GET(self):
        if self.path == "/clients":
            if not self.check_auth(): return
            
            cmd = "wg show wg0 dump"
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
            
            clients = []
            lines = result.stdout.strip().splitlines()
            now = int(subprocess.check_output(["date", "+%s"]).decode().strip())
            
            for line in lines[1:]:
                parts = line.split("\t")
                if len(parts) >= 8:
                    pubkey = parts[0]
                    endpoint = parts[2] if parts[2] != "(none)" else None
                    allowed_ips = parts[3]
                    latest_handshake = int(parts[4])

                    clients.append({
                        "pubkey": pubkey,
                        "ip": allowed_ips.replace("/32", ""),
                        "endpoint": endpoint,
                        "latest_handshake_epoch": latest_handshake,
                        "transfer_rx_bytes": int(parts[5]),
                        "transfer_tx_bytes": int(parts[6]),
                        "is_online": (latest_handshake > 0 and (now - latest_handshake) < 180)
                    })

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"clients": clients, "total_clients": len(clients)}, indent=2).encode())
            return
            
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if not self.check_auth(): return

        if self.path == "/register":
            try:
                content_length = int(self.headers['Content-Length'])
                data = json.loads(self.rfile.read(content_length))
                client_pubkey = data.get("pubkey")
                hostname = data.get("hostname", "").strip().lower().replace(" ", "-")

                if not client_pubkey:
                    self.send_response(400); self.end_headers(); return

                with open(WG_CONF, "r") as f:
                    conf_content = f.read()

                if client_pubkey in conf_content:
                    lines = conf_content.splitlines()
                    assigned_ip = None
                    for idx, line in enumerate(lines):
                        if client_pubkey in line:
                            assigned_ip = lines[idx+1].split("=")[1].strip().replace("/32", "")
                            break
                else:
                    used_ips = [line.split("=")[1].strip().split("/")[0] for line in conf_content.splitlines() if "AllowedIPs" in line]
                    assigned_ip = None
                    for i in range(2, 255):
                        candidate = f"10.8.0.{i}"
                        if candidate not in used_ips:
                            assigned_ip = candidate
                            break

                    with open(WG_CONF, "a") as f:
                        f.write(f"\n[Peer]\nPublicKey = {client_pubkey}\nAllowedIPs = {assigned_ip}/32\n")

                    sync_wireguard()

                # Per REST API an Pi-hole senden
                if hostname and assigned_ip:
                    pihole_add_dns_v6(assigned_ip, hostname)

                response = {
                    "ip": assigned_ip,
                    "hostname": f"{hostname}.vpn" if hostname else None,
                    "server_pubkey": read_file_strip("/etc/wireguard/keys/server_public.key")
                }
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(response).encode())
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(str(e).encode())
            return

        if self.path == "/unregister":
            try:
                content_length = int(self.headers['Content-Length'])
                data = json.loads(self.rfile.read(content_length))
                target_pubkey = data.get("pubkey")
                target_ip = data.get("ip")

                if not target_pubkey and not target_ip:
                    self.send_response(400); self.end_headers(); return

                with open(WG_CONF, "r") as f:
                    content = f.read()

                sections = content.split("\n[Peer]\n")
                new_sections = [sections[0]]
                removed = False
                removed_ip = None

                for section in sections[1:]:
                    if (target_pubkey and target_pubkey in section) or (target_ip and f"{target_ip}/32" in section):
                        removed = True
                        for line in section.splitlines():
                            if "AllowedIPs" in line:
                                removed_ip = line.split("=")[1].strip().replace("/32", "")
                        continue
                    new_sections.append(section)

                if removed:
                    with open(WG_CONF, "w") as f:
                        f.write("\n[Peer]\n".join(new_sections))

                    sync_wireguard()

                    # Per REST API aus Pi-hole löschen
                    if removed_ip:
                        pihole_remove_dns_v6(removed_ip)

                    msg = {"status": "success", "message": "Client und DNS-Eintrag erfolgreich entfernt."}
                    code = 200
                else:
                    msg = {"status": "error", "message": "Client nicht gefunden."}
                    code = 404

                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(msg).encode())
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(str(e).encode())
            return

        self.send_response(404)
        self.end_headers()

if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", 8050), RegisterHandler)
    server.serve_forever()
PYEOF

chmod +x /usr/local/bin/wg_register_api.py

# 6. Systemd Service einrichten
echo "=== 6. Richte Systemd Service ein ==="
cat << EOF > /etc/systemd/system/wg-api.service
[Unit]
Description=WireGuard Dynamic Registration API
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/wg_register_api.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart wg-api || systemctl enable --now wg-api || error_exit "Konnte wg-api.service nicht starten."

# 7. Firewall einrichten
echo "=== 7. Firewall konfigurieren (UFW) ==="
ufw default deny incoming 2>/dev/null || true
ufw default allow outgoing 2>/dev/null || true
ufw allow 22/tcp 2>/dev/null || true
ufw allow 51820/udp 2>/dev/null || true
ufw allow 8050/tcp 2>/dev/null || true
ufw allow in on wg0 2>/dev/null || true
ufw --force enable 2>/dev/null || true

PUBLIC_IP=$(curl -s --connect-timeout 3 ifconfig.me || curl -s --connect-timeout 3 api.ipify.org || echo "Unbekannt")
PIHOLE_CONFIGURED_URL=$(cat "${PIHOLE_URL_FILE}" 2>/dev/null || echo "Nicht konfiguriert")

echo "=================================================="
echo " SERVER SETUP ERFOLGREICH ABGESCHLOSSEN!"
echo "=================================================="
echo " Öffentliche IP:      ${PUBLIC_IP}"
echo " WireGuard Port:     51820 (UDP)"
echo " API Port:           8050 (TCP)"
echo " Dein API-Token:     ${API_TOKEN}"
echo " Pi-hole Target:     ${PIHOLE_CONFIGURED_URL}"
echo "=================================================="