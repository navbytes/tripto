#!/usr/bin/env python3
"""Headless App Store Connect status check for Tripto (read-only).

Prints the appStoreVersion state for a version (default 1.2) and the
recent review submissions. Used by the twice-daily submission monitor.

Usage: python3 scripts/asc-status.py [versionString]
Auth: ~/.appstoreconnect/private_keys/AuthKey_KRA9W469V6.p8 (see note.txt there).
"""
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

import jwt

KEY_DIR = pathlib.Path.home() / ".appstoreconnect/private_keys"
KEY_ID = "KRA9W469V6"
ISSUER = "7211675c-62ec-41d2-b54f-5c4598db72d9"
APP_ID = "6789917838"  # Tripto — Trip Organizer

now = int(time.time())
token = jwt.encode(
    {"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
    (KEY_DIR / f"AuthKey_{KEY_ID}.p8").read_text(),
    algorithm="ES256",
    headers={"kid": KEY_ID},
)


def get(path: str) -> dict:
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com" + path,
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} on {path}: {e.read().decode()}", file=sys.stderr)
        raise SystemExit(1)


version = sys.argv[1] if len(sys.argv) > 1 else "1.2"

for v in get(f"/v1/apps/{APP_ID}/appStoreVersions?filter[versionString]={version}&limit=5")["data"]:
    a = v["attributes"]
    print(f"appStoreVersion {a['versionString']}: {a['appStoreState']} (created {a['createdDate']})")

for s in get(f"/v1/reviewSubmissions?filter[app]={APP_ID}&filter[platform]=IOS&limit=5")["data"]:
    a = s["attributes"]
    print(f"reviewSubmission {s['id']}: {a['state']} (submitted {a.get('submittedDate')})")
