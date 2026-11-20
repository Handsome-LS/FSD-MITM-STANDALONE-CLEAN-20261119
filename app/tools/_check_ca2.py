import re
from cryptography import x509
from cryptography.hazmat.primitives import serialization

p = r"C:\Users\USER\Documents\xwechat_files\wxid_XXXXXXXXXXXXXXXX\msg\file\2026-11\mitmproxy-ca.pem"
data = open(p, "rb").read()
blocks = re.findall(rb"-----BEGIN ([A-Z ]+)-----.*?-----END \1-----", data, re.S)
print("pem blocks:", [b.decode() for b in blocks])

key = serialization.load_pem_private_key(data, password=None)
kp = key.public_key().public_bytes(
    serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
)
print("priv key curve:", getattr(key.curve, "name", "?"), "| bits:", key.key_size)

for m in re.finditer(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", data, re.S):
    cert = x509.load_pem_x509_certificate(m.group(0))
    cp = cert.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    print("---")
    print("subject  :", cert.subject.rfc4514_string())
    print("issuer   :", cert.issuer.rfc4514_string())
    print("sigalg   :", cert.signature_algorithm_oid._name)
    print("pubkey   :", cert.public_key().__class__.__name__, getattr(cert.public_key(), "key_size", ""))
    print("matches private key:", cp == kp)
    try:
        ku = cert.extensions.get_extension_for_class(x509.KeyUsage).value
        print("keyusage :", "cs=", ku.key_cert_sign, "crl=", ku.crl_sign, "digitalSignature=", ku.digital_signature)
    except Exception as e:
        print("keyusage : none")
    try:
        bc = cert.extensions.get_extension_for_class(x509.BasicConstraints).value
        print("basiccons:", "ca=", bc.ca, "pathlen=", bc.path_length)
    except Exception:
        pass
    try:
        eku = cert.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value
        print("eku      :", [e._name for e in eku])
    except Exception:
        print("eku      : none")
