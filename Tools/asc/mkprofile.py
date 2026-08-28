import base64, json, urllib.request, urllib.error, os
from asc import token, get

def post(path, payload):
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com" + path,
        data=json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + token(),
                 "Content-Type": "application/json"},
        method="POST")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

# ids we need
_, bids = get("/v1/bundleIds?limit=200")
bid = next(d["id"] for d in bids["data"]
           if d["attributes"]["identifier"] == "com.xiangyang.albumcompact")
_, certs = get("/v1/certificates?limit=200")
cert = next(d for d in certs["data"]
            if d["attributes"]["certificateType"] == "DISTRIBUTION")
print(f"bundleId  id = {bid}")
print(f"cert      id = {cert['id']}  (到期 {cert['attributes']['expirationDate']})")

st, body = post("/v1/profiles", {"data": {
    "type": "profiles",
    "attributes": {"name": "AlbumCompact App Store",
                   "profileType": "IOS_APP_STORE"},
    "relationships": {
        "bundleId":     {"data": {"type": "bundleIds",    "id": bid}},
        "certificates": {"data": [{"type": "certificates","id": cert["id"]}]},
    }}})

print(f"\nPOST /v1/profiles -> HTTP {st}")
if st >= 400:
    for e in body.get("errors", []):
        print("  !!", e.get("code"), "-", e.get("detail", "")[:200])
    raise SystemExit(1)

a = body["data"]["attributes"]
print(f"  名称   {a['name']}")
print(f"  类型   {a['profileType']}")
print(f"  状态   {a['profileState']}")
print(f"  UUID   {a['uuid']}")
print(f"  到期   {a['expirationDate']}")

dst = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
os.makedirs(dst, exist_ok=True)
path = os.path.join(dst, a["uuid"] + ".mobileprovision")
open(path, "wb").write(base64.b64decode(a["profileContent"]))
print(f"\n已安装 -> {path}")
