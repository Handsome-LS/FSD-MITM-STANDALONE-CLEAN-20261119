import re
import sys
from pathlib import Path

src = Path(r"C:\Users\USER\Documents\xwechat_files\wxid_XXXXXXXXXXXXXXXX\msg\file\2026-11\mitmproxy-ca.pem")
out = Path(r"C:\fsd-mitm\certs")
out.mkdir(parents=True, exist_ok=True)

raw = src.read_bytes()
certs = re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", raw, re.S)
key = re.search(rb"-----BEGIN EC PRIVATE KEY-----.*?-----END EC PRIVATE KEY-----", raw, re.S)

(out / "1-leaf-ca.pem").write_bytes(certs[0] + b"\n")
(out / "2-intermediate.pem").write_bytes(certs[1] + b"\n")
(out / "3-root-emsign-ecc-g3.pem").write_bytes(certs[2] + b"\n")
if key:
    (out / "ca-key.pem").write_bytes(key.group(0) + b"\n")
    (out / "mitmproxy-ca.pem").write_bytes(key.group(0) + b"\n" + certs[0] + b"\n" + certs[1] + b"\n")
print("written:", sorted(p.name for p in out.glob("*.pem")))
