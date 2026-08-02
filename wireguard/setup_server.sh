#!/bin/bash
set -e

# 1. Root-Check
if [ "$EUID" -ne 0 ]; then
  echo "Fehler: Bitte führe das Skript mit 'sudo' aus!"
  exit 1
fi

echo "=== 1. Installiere System-Pakete ==="
apt-get update && apt-get install -y wireguard wireguard-tools ufw iptables python3 curl jq

KEY_DIR="/etc/wireguard/keys"
mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

# 2. Server Keys & API Token generieren
echo "=== 2. Generiere Server-Schlüssel & API-Token ==="
if [ ! -f "${KEY_DIR}/server_private.key" ]; then
  wg genkey | tee "${KEY_DIR}/server_private.key" | wg pubkey > "${KEY_DIR}/server_public.key"
  head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24 > "${KEY_DIR}/api_token.txt"
  chmod 600 "${KEY_DIR}"/*
fi

SERVER_PRIV=$(cat "${KEY_DIR}/server_private.key")
SERVER_PUB=$(cat "${KEY_DIR}/server_public.key")
API_TOKEN=$(cat "${KEY_DIR}/api_token.txt")
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

# 3. /etc/wireguard/wg0.conf Grundgerüst erstellen
echo "=== 3. Erstelle Server WireGuard-Konfiguration ==="
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
sysctl -p /etc/sysctl.d/99-wireguard.conf || true

systemctl enable --now wg-quick@wg0

# 4. Registrierungs-API in Python schreiben
echo "=== 4. Erstelle API-Dienst (/usr/local/bin/wg_register_api.py) ==="
cat << 'EOF' > /usr/local/bin/wg_register_api.py
import http.server
import json
import subprocess

API_TOKEN_FILE = "/etc/wireguard/keys/api_token.txt"
WG_CONF = "/etc/wireguard/wg0.conf"

with open(API_TOKEN_FILE) as f:
    VALID_TOKEN = f.read().strip()

def sync_wireguard():
    cmd = "wg-quick strip wg0 > /tmp/wg_stripped.conf && wg syncconf wg0 /tmp/wg_stripped.conf"
    subprocess.run(cmd, shell=True, check=True)

class RegisterHandler(http.server.BaseHTTPRequestHandler):
    def check_auth(self):
        token = self.headers.get("X-API-Token")
        if token != VALID_TOKEN:
            self.send_response(401)
            self.end_headers()
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
            content_length = int(self.headers['Content-Length'])
            data = json.loads(self.rfile.read(content_length))
            client_pubkey = data.get("pubkey")

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

            response = {"ip": assigned_ip, "server_pubkey": open("/etc/wireguard/keys/server_public.key").read().strip()}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
            return

        if self.path == "/unregister":
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

            for section in sections[1:]:
                if (target_pubkey and target_pubkey in section) or (target_ip and f"{target_ip}/32" in section):
                    removed = True
                    continue
                new_sections.append(section)

            if removed:
                with open(WG_CONF, "w") as f:
                    f.write("\n[Peer]\n".join(new_sections))

                sync_wireguard()
                msg = {"status": "success", "message": "Client entfernt."}
                code = 200
            else:
                msg = {"status": "error", "message": "Client nicht gefunden."}
                code = 404

            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(msg).encode())
            return

        self.send_response(404)
        self.end_headers()

if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", 8050), RegisterHandler)
    server.serve_forever()
EOF

# 5. Systemd Service für die API anlegen
echo "=== 5. Richtete Systemd Service ein ==="
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
systemctl enable --now wg-api

# 6. Firewall auf Server konfigurieren
echo "=== 6. Konfiguriere Firewall (UFW) ==="
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp        # SSH
ufw allow 51820/udp     # WireGuard VPN Port
ufw allow 8050/tcp      # Registrierungs-API Port
ufw allow in on wg0     # VPN Internal Traffic
ufw --force enable

PUBLIC_IP=$(curl -s ifconfig.me || curl -s api.ipify.org)

echo "=================================================="
echo " SERVER SETUP ERFOLGREICH ABGESCHLOSSEN!"
echo "=================================================="
echo " Public IP / Endpoint: ${PUBLIC_IP}"
echo " API Port:             8050"
echo " Deines API-Token:      ${API_TOKEN}"
echo ""
echo " WICHTIG: Trage ${API_TOKEN} und deine Public IP/DynDNS"
echo " im Client-Skript ein!"
echo "=================================================="