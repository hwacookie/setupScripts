import http.server
import json
import subprocess
import os

API_TOKEN_FILE = "/etc/wireguard/keys/api_token.txt"
WG_CONF = "/etc/wireguard/wg0.conf"

with open(API_TOKEN_FILE) as f:
    VALID_TOKEN = f.read().strip()


def sync_wireguard():
    """Lädt die wg0.conf live neu, ohne bestehende Verbindungen zu trennen."""
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
        # ENDPOINT 1: Alle Clients anzeigen (/clients)
        if self.path == "/clients":
            if not self.check_auth():
                return

            # Liest den aktuellen Live-Status direkt aus WireGuard aus
            cmd = "wg show wg0 dump"
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True)

            clients = []
            lines = result.stdout.strip().splitlines()

            # Erste Zeile ist der Server selbst, danach folgen die Peers
            for line in lines[1:]:
                parts = line.split("\t")
                if len(parts) >= 8:
                    pubkey = parts[0]
                    endpoint = parts[2] if parts[2] != "(none)" else None
                    allowed_ips = parts[3]
                    latest_handshake = int(
                        parts[4]
                    )  # Unix Timestamp (0 = nie verbunden)
                    rx_bytes = int(parts[5])
                    tx_bytes = int(parts[6])

                    clients.append(
                        {
                            "pubkey": pubkey,
                            "ip": allowed_ips.replace("/32", ""),
                            "endpoint": endpoint,
                            "latest_handshake_epoch": latest_handshake,
                            "transfer_rx_bytes": rx_bytes,
                            "transfer_tx_bytes": tx_bytes,
                            "is_online": (
                                latest_handshake > 0
                                and (
                                    int(subprocess.check_output(["date", "+%s"]))
                                    - latest_handshake
                                )
                                < 180
                            ),
                        }
                    )

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(
                json.dumps(
                    {"clients": clients, "total_clients": len(clients)}, indent=2
                ).encode()
            )
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if not self.check_auth():
            return

        # ENDPOINT 2: Neuen Client registrieren (/register)
        if self.path == "/register":
            content_length = int(self.headers["Content-Length"])
            data = json.loads(self.rfile.read(content_length))
            client_pubkey = data.get("pubkey")

            if not client_pubkey:
                self.send_response(400)
                self.end_headers()
                return

            with open(WG_CONF, "r") as f:
                conf_content = f.read()

            if client_pubkey in conf_content:
                lines = conf_content.splitlines()
                assigned_ip = None
                for idx, line in enumerate(lines):
                    if client_pubkey in line:
                        assigned_ip = (
                            lines[idx + 1].split("=")[1].strip().replace("/32", "")
                        )
                        break
            else:
                used_ips = [
                    line.split("=")[1].strip().split("/")[0]
                    for line in conf_content.splitlines()
                    if "AllowedIPs" in line
                ]
                assigned_ip = None
                for i in range(2, 255):
                    candidate = f"10.8.0.{i}"
                    if candidate not in used_ips:
                        assigned_ip = candidate
                        break

                with open(WG_CONF, "a") as f:
                    f.write(
                        f"\n[Peer]\nPublicKey = {client_pubkey}\nAllowedIPs = {assigned_ip}/32\n"
                    )

                sync_wireguard()

            response = {
                "ip": assigned_ip,
                "server_pubkey": open("/etc/wireguard/keys/server_public.key")
                .read()
                .strip(),
            }
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
            return

        # ENDPOINT 3: Client entfernen (/unregister)
        if self.path == "/unregister":
            content_length = int(self.headers["Content-Length"])
            data = json.loads(self.rfile.read(content_length))
            target_pubkey = data.get("pubkey")
            target_ip = data.get("ip")

            if not target_pubkey and not target_ip:
                self.send_response(400)
                self.end_headers()
                return

            with open(WG_CONF, "r") as f:
                content = f.read()

            # Sektionen parsen und den gesuchten Peer entfernen
            sections = content.split("\n[Peer]\n")
            new_sections = [sections[0]]  # [Interface] behalten
            removed = False

            for section in sections[1:]:
                if (target_pubkey and target_pubkey in section) or (
                    target_ip and f"{target_ip}/32" in section
                ):
                    removed = True
                    continue
                new_sections.append(section)

            if removed:
                with open(WG_CONF, "w") as f:
                    f.write("\n[Peer]\n".join(new_sections))

                sync_wireguard()
                msg = {"status": "success", "message": "Client erfolgreich entfernt."}
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
