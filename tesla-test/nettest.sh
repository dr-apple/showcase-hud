#!/bin/sh
# Showcase for Tesla – network test for the iPad hotspot.
# Run on the jailbroken iPad while Showcase is connected (hotspot on):
#   sudo sh nettest.sh
# Needs: python3 (Sileo). Optional: openssl (for the HTTPS test).
# Adds 100.96.0.1 to the hotspot interface and serves a small test page on
# http://100.96.0.1, http://172.20.10.1 and (with openssl) https on both.
# Ctrl+C stops the test and removes the extra address.
set -e
ALIAS_IP="${ALIAS_IP:-100.96.0.1}"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
WORK="${TMPDIR:-/tmp}/showcase-nettest"
mkdir -p "$WORK"

PY=""
for p in /var/jb/usr/bin/python3 /usr/bin/python3 /usr/local/bin/python3; do
  [ -x "$p" ] && PY="$p" && break
done
[ -n "$PY" ] || { echo "python3 fehlt: in Sileo das Paket python3 installieren." >&2; exit 1; }

IFACE=""
if [ -z "$NO_ALIAS" ]; then
  [ "$(id -u)" = 0 ] || { echo "Bitte mit sudo starten." >&2; exit 1; }
  IFACE="$(ifconfig | awk '/^[a-z]/{i=$1; sub(":","",i)} /inet 172\.20\.10\.1 /{print i; exit}')"
  if [ -z "$IFACE" ]; then
    echo "Kein Hotspot gefunden (172.20.10.1). Erst Showcase starten und CarPlay verbinden." >&2
    exit 1
  fi
  ifconfig "$IFACE" inet "$ALIAS_IP" netmask 255.255.255.0 alias
  trap 'ifconfig "$IFACE" inet "$ALIAS_IP" -alias 2>/dev/null; echo; echo "Adresse $ALIAS_IP entfernt."' EXIT INT TERM
  echo "Hotspot-Schnittstelle: $IFACE, zusätzliche Adresse: $ALIAS_IP"
fi

CERT=""
OPENSSL=""
for p in /var/jb/usr/bin/openssl /usr/bin/openssl /opt/homebrew/bin/openssl; do
  [ -x "$p" ] && OPENSSL="$p" && break
done
if [ -n "$OPENSSL" ]; then
  if [ ! -f "$WORK/cert.pem" ]; then
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=$ALIAS_IP" \
      -addext "subjectAltName=IP:$ALIAS_IP,IP:172.20.10.1" \
      -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1 || true
  fi
  [ -f "$WORK/cert.pem" ] && CERT="$WORK"
else
  echo "openssl fehlt: HTTPS-Test wird übersprungen (in Sileo: openssl)."
fi

echo
echo "Im Tesla-Browser nacheinander öffnen:"
echo "  http://$ALIAS_IP:$HTTP_PORT/"
echo "  http://172.20.10.1:$HTTP_PORT/"
[ -n "$CERT" ] && echo "  https://$ALIAS_IP:$HTTPS_PORT/" && echo "  https://172.20.10.1:$HTTPS_PORT/"
echo "Jeder Aufruf erscheint unten. Stopp mit Ctrl+C."
echo

"$PY" -I - "$HTTP_PORT" "$HTTPS_PORT" "$CERT" "$ALIAS_IP" <<'PYEOF'
import http.server, json, socketserver, ssl, sys, threading, time

http_port, https_port, cert_dir, alias_ip = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]

PAGE = """<!doctype html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>iPad erreichbar</title>
<style>body{background:#0d0f12;color:#e8eaed;font:20px/1.5 sans-serif;padding:24px}
.ok{color:#3ccf7a}.bad{color:#f05252}td{padding:6px 18px 6px 0}a{color:#4c8dff}</style></head><body>
<h1 class="ok">&#10003; Der Tesla erreicht das iPad</h1>
<table id="t"></table><p>Weitere Adressen testen:</p><ul id="l"></ul>
<script>
const r = {url: location.href, secureContext: isSecureContext, webCodecs: 'VideoDecoder' in window,
  webSocket: 'WebSocket' in window, ua: navigator.userAgent, time: new Date().toLocaleTimeString('de-DE')};
document.getElementById('t').innerHTML = [['Adresse', r.url], ['Sichere Seite', r.secureContext],
  ['WebCodecs', r.webCodecs], ['Uhrzeit', r.time]].map(([k, v]) =>
  `<tr><td>${k}</td><td class="${v === false ? 'bad' : v === true ? 'ok' : ''}">${v === true ? 'ja' : v === false ? 'nein' : v}</td></tr>`).join('');
const urls = __URLS__;
document.getElementById('l').innerHTML = urls.map(u => `<li><a href="${u}">${u}</a></li>`).join('');
fetch('/report', {method: 'POST', body: JSON.stringify(r)}).catch(() => {});
</script></body></html>"""

urls = [f"http://{alias_ip}:{http_port}/", f"http://172.20.10.1:{http_port}/"]
if cert_dir:
    urls += [f"https://{alias_ip}:{https_port}/", f"https://172.20.10.1:{https_port}/"]
body = PAGE.replace("__URLS__", json.dumps(urls)).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        try:
            r = json.loads(data)
            print(f"{time.strftime('%H:%M:%S')}  {r.get('url')}  sicher={r.get('secureContext')}  "
                  f"WebCodecs={r.get('webCodecs')}", flush=True)
        except ValueError:
            pass
        self.send_response(204)
        self.end_headers()

    def log_message(self, fmt, *args):
        print(f"{time.strftime('%H:%M:%S')}  {self.client_address[0]}  {fmt % args}", flush=True)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


servers = [Server(("0.0.0.0", http_port), Handler)]
if cert_dir:
    s = Server(("0.0.0.0", https_port), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(f"{cert_dir}/cert.pem", f"{cert_dir}/key.pem")
    s.socket = ctx.wrap_socket(s.socket, server_side=True)
    servers.append(s)
for s in servers[1:]:
    threading.Thread(target=s.serve_forever, daemon=True).start()
try:
    servers[0].serve_forever()
except KeyboardInterrupt:
    pass
PYEOF
