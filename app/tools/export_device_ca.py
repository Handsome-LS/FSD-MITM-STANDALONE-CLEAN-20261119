"""导出可安装到车机/设备的信任证书。

1) mitmproxy 自带 CA（confdir\\mitmproxy-ca-cert.cer/.pem）
2) --emudhra 实际签名用的中间 CA（EM OV TLS CA - G3C）—— 设备不信任 emSign 根时再装它
"""
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import serialization

import mitmproxy.certs as mc

out = Path(r"C:\fsd-mitm\certs2")
out.mkdir(parents=True, exist_ok=True)

certs = x509.load_pem_x509_certificates(mc.EMUDHRA_CHAIN_PEM)
signer = certs[0]
(out / "device-trust-EMOV-G3C.pem").write_bytes(
    signer.public_bytes(serialization.Encoding.PEM)
)
(out / "device-trust-EMOV-G3C.cer").write_bytes(
    signer.public_bytes(serialization.Encoding.DER)
)

ca = out / "mitmproxy-ca-cert.pem"
if ca.exists():
    data = ca.read_bytes()
    c = x509.load_pem_x509_certificate(data)
    (out / "device-trust-mitmproxy.cer").write_bytes(c.public_bytes(serialization.Encoding.DER))

for p in sorted(out.glob("device-trust-*")):
    print(f"{p.name:36} {p.stat().st_size:6} B | {p}")
print("signer:", signer.subject.rfc4514_string())
