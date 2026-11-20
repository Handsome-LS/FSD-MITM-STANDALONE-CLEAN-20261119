"""Regenerate mitmproxy CA export files for the TESL lab confdir."""
from pathlib import Path
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.serialization import pkcs12

confdir = Path(sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\USER\Desktop\TESL\f50-lab-local-ca")
raw = (confdir / "mitmproxy-ca.pem").read_bytes()

key = serialization.load_pem_private_key(raw, password=None)
certs = x509.load_pem_x509_certificates(raw)
ca, chain = certs[0], certs[1:]

assert (ca.public_key().public_bytes(
    serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
) == key.public_key().public_bytes(
    serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
)), "私钥与 CA 证书不匹配"

# 客户端安装用：CA + 中间 + 根（证书链完整，path building 不需要 AIA）
(confdir / "mitmproxy-ca-cert.pem").write_bytes(
    b"".join(c.public_bytes(serialization.Encoding.PEM) for c in certs)
)
(confdir / "mitmproxy-ca-cert.cer").write_bytes(ca.public_bytes(serialization.Encoding.DER))

p12 = pkcs12.serialize_key_and_certificates(
    name=b"f50-lab-ca",
    key=key,
    cert=ca,
    cas=chain or None,
    encryption_algorithm=serialization.NoEncryption(),
)
(confdir / "mitmproxy-ca-cert.p12").write_bytes(p12)
(confdir / "mitmproxy-ca.p12").write_bytes(p12)

fp = ca.fingerprint(hashes.SHA256()).hex(":").upper()
print("CA      :", ca.subject.rfc4514_string())
print("issuer  :", ca.issuer.rfc4514_string())
print("sha256  :", fp)
print("chain   :", ", ".join(c.subject.rfc4514_string() for c in chain) or "-")
print("files   :", ", ".join(sorted(p.name for p in confdir.glob("mitmproxy-*"))))
