import base64, json, subprocess, sys, time, urllib.request, os

KEY_ID    = "N3G5466NMU"
ISSUER_ID = "11e1deca-7f34-4781-975a-f4eab3f5d9eb"
KEY_PATH  = os.path.expanduser("~/.appstoreconnect/private_keys/AuthKey_N3G5466NMU.p8")

def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=")

def der_to_raw(der):
    """ES256 JWTs need raw R||S (64 bytes); openssl emits DER SEQUENCE."""
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 3 + (der[1] & 0x7f) - 1
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        ln = der[i+1]; v = der[i+2:i+2+ln]; i += 2 + ln
        v = v.lstrip(b"\x00").rjust(32, b"\x00")
        out += v
    return out

def token():
    now = int(time.time())
    hdr = {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
    pl  = {"iss": ISSUER_ID, "iat": now, "exp": now + 600,
           "aud": "appstoreconnect-v1"}
    msg = b64u(json.dumps(hdr,separators=(',',':')).encode()) + b"." + \
          b64u(json.dumps(pl ,separators=(',',':')).encode())
    der = subprocess.run(["openssl","dgst","-sha256","-sign",KEY_PATH],
                         input=msg, capture_output=True, check=True).stdout
    return (msg + b"." + b64u(der_to_raw(der))).decode()

def get(path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path,
                                 headers={"Authorization": "Bearer " + token()})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

if __name__ == "__main__":
    for label, path in [
        ("身份/权限 (users)",        "/v1/users?limit=1"),
        ("Bundle IDs",              "/v1/bundleIds?limit=200&fields[bundleIds]=identifier,name,platform"),
        ("证书 (certificates)",      "/v1/certificates?limit=200&fields[certificates]=certificateType,displayName,expirationDate"),
        ("描述文件 (profiles)",      "/v1/profiles?limit=200&fields[profiles]=name,profileType,profileState,uuid"),
        ("App 记录 (apps)",          "/v1/apps?limit=200&fields[apps]=name,bundleId"),
    ]:
        st, body = get(path)
        print(f"\n=== {label}  ->  HTTP {st} ===")
        if st >= 400:
            for e in body.get("errors", []):
                print("   !!", e.get("code"), "-", e.get("detail","")[:160])
            continue
        data = body.get("data", [])
        print(f"   {len(data)} 条")
        for d in data:
            a = d.get("attributes", {})
            print("   ·", {k: v for k, v in a.items() if v is not None})
