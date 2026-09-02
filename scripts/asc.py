#!/usr/bin/env python3
"""Мини-клиент App Store Connect API: подписывает JWT и ходит в апи.
Использование: asc.py GET /v1/apps  |  asc.py POST /v1/apps '<json>'"""
import json, os, sys, time, urllib.request, base64
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils

KEY_ID = os.environ.get("ASC_KEY_ID", "75ZP2J5D59")
ISSUER = os.environ.get("ASC_ISSUER", "69a6de8e-0e6d-47e3-e053-5b8c7c11a4d1")
KEY_PATH = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")
BASE = "https://api.appstoreconnect.apple.com"

def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def token() -> str:
    with open(KEY_PATH, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    now = int(time.time())
    header = {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
    payload = {"iss": ISSUER, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64(json.dumps(header).encode())}.{b64(json.dumps(payload).encode())}".encode()
    der = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = asym_utils.decode_dss_signature(der)
    sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return f"{signing_input.decode()}.{b64(sig)}"

def call(method: str, path: str, body=None):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token())
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw.decode(errors="replace")[:800]}

if __name__ == "__main__":
    method, path = sys.argv[1], sys.argv[2]
    body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    status, out = call(method, path, body)
    print(status)
    print(json.dumps(out, indent=2, ensure_ascii=False)[:4000])
