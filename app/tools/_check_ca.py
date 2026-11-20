import sys
from cryptography import x509
from cryptography.hazmat.primitives import serialization

p = r"C:\Users\USER\Documents\xwechat_files\wxid_XXXXXXXXXXXXXXXX\msg\file\2026-11\mitmproxy-ca.pem"
data = open(p, "rb").read()
try:
    key = serialization.load_pem_private_key(data, password=None)
    print("key OK:", key.__class__.__name__, key.key_size)
except Exception as e:
    print("key FAIL:", type(e).__name__, str(e)[:160])
idx = data.index(b"-----BEGIN CERTIFICATE-----")
cert = x509.load_pem_x509_certificate(data[idx:])
print("subject :", cert.subject.rfc4514_string())
print("issuer  :", cert.issuer.rfc4514_string())
print("not_after:", cert.not_valid_after_utc)
try:
    san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    print("SAN(", len(list(san)), "):", ", ".join(str(s) for s in list(san))[:400])
except Exception as e:
    print("SAN: none", e)
print("is_ca:", end=" ")
try:
    print(cert.extensions.get_extension_for_class(x509.BasicConstraints).value.ca)
except Exception as e:
    print("unknown", e)
