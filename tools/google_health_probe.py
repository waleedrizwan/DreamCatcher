#!/usr/bin/env python3
"""Check whether a personal Google Cloud project can read the Google Health API.

No Fitbit needed: an account with no device should get 200 + empty data,
while a blocked project gets 403.

Usage:
    python3 tools/google_health_probe.py path/to/client_secret.json

The OAuth client must be a "Desktop app" client. Tokens are saved to
~/.config/google-health-probe/tokens.json (outside the repo, mode 600).
Standard library only.
"""

import base64
import hashlib
import http.server
import json
import os
import secrets
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
API = "https://health.googleapis.com/v4/users/me/dataTypes/{}/dataPoints"
PORT = 8765
REDIRECT = f"http://127.0.0.1:{PORT}/"
SCOPES = [
    "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
    "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
    "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
]
# Kebab-case type names from developers.google.com/health/data-types.
# A 404/400 on one of these means the name is wrong, not that access is blocked.
DATA_TYPES = [
    "heart-rate",
    "heart-rate-variability",
    "oxygen-saturation",
    "daily-oxygen-saturation",
    "respiratory-rate-sleep-summary",
    "sleep",
    "steps",
]
TOKEN_FILE = os.path.expanduser("~/.config/google-health-probe/tokens.json")


def load_client(path):
    with open(path) as f:
        data = json.load(f)
    client = data.get("installed") or data.get("web")
    if not client:
        sys.exit("client_secret.json has no 'installed' or 'web' section")
    if "web" in data:
        print("Warning: this is a Web client. Create a 'Desktop app' client instead,"
              " or add http://127.0.0.1:8765/ as an authorized redirect URI.")
    return client["client_id"], client["client_secret"]


def get_code(client_id):
    """Run the browser consent flow and return (code, verifier)."""
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    params = {
        "client_id": client_id,
        "redirect_uri": REDIRECT,
        "response_type": "code",
        "scope": " ".join(SCOPES),
        "access_type": "offline",
        "prompt": "consent",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    }
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if "code" not in q and "error" not in q:
                self.send_response(404)
                self.end_headers()
                return
            result.update({k: v[0] for k, v in q.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Done. You can close this tab and go back to the terminal.")
            threading.Thread(target=self.server.shutdown).start()

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    url = AUTH_URL + "?" + urllib.parse.urlencode(params)
    print("Opening the Google sign-in page. If it doesn't open, paste this URL:\n" + url + "\n")
    webbrowser.open(url)
    server.serve_forever()

    if "error" in result:
        sys.exit("Sign-in failed: " + result["error"])
    if result.get("state") != state:
        sys.exit("State mismatch, aborting")
    return result["code"], verifier


def post(url, fields):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(fields).encode())
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"Token request failed ({e.code}): {e.read().decode()}")


def save_tokens(tokens):
    os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(tokens, f, indent=2)


def query(data_type, access_token):
    req = urllib.request.Request(
        API.format(data_type) + "?page_size=5",
        headers={"Authorization": "Bearer " + access_token, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        try:
            return e.code, json.loads(body)
        except ValueError:
            return e.code, {"raw": body[:500]}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    client_id, client_secret = load_client(sys.argv[1])

    code, verifier = get_code(client_id)
    tokens = post(TOKEN_URL, {
        "code": code,
        "client_id": client_id,
        "client_secret": client_secret,
        "redirect_uri": REDIRECT,
        "grant_type": "authorization_code",
        "code_verifier": verifier,
    })
    save_tokens(tokens)

    print("== Login")
    print("refresh token received:", "yes" if tokens.get("refresh_token") else "NO")
    expires = tokens.get("refresh_token_expires_in")
    if expires:
        print(f"refresh token EXPIRES in {int(expires) // 86400} days"
              " (app is in Testing mode; publish it to Production to remove this)")
    else:
        print("refresh token has no expiry (good: no weekly re-login)")
    print("granted scopes:", tokens.get("scope", "?"))

    print("\n== API")
    for data_type in DATA_TYPES:
        status, body = query(data_type, tokens["access_token"])
        if status == 200:
            n = len(body.get("dataPoints", []))
            print(f"{data_type:32} 200 OK, {n} data points")
        else:
            err = body.get("error", {})
            msg = err.get("message") or body.get("raw", "")
            print(f"{data_type:32} {status} {err.get('status', '')}: {msg[:200]}")

    print("\nRead it like this:")
    print("  200 OK (even with 0 data points) = access works")
    print("  403 PERMISSION_DENIED            = Google is blocking this project")
    print("  400/404 on one type only         = wrong type name, ignore that row")


if __name__ == "__main__":
    main()
