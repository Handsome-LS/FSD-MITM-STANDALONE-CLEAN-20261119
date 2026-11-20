"""Probe the TESL F50 lab proxy after CA replacement."""
import os
import socket
import ssl

from cryptography import x509
from cryptography.hazmat.primitives import serialization

CONFDIR = r"C:\Users\USER\Desktop\TESL\f50-lab-local-ca"
HOST = "feature-config.f50.test"
PORT = int(os.environ.get("TESL_PROXY_PORT", "8082"))

raw = open(os.path.join(CONFDIR, "mitmproxy-ca.pem"), "rb").read()
certs = x509.load_pem_x509_certificates(raw)
root = certs[-1]
root_path = os.path.join(os.environ.get("TEMP", r"C:\Windows\Temp"), "emsign-ecc-root-g3.pem")
with open(root_path, "wb") as fh:
    fh.write(root.public_bytes(serialization.Encoding.PEM))
print("trust anchor:", root.subject.rfc4514_string())

ctx = ssl.create_default_context(cafile=root_path)
ctx.check_hostname = True


def new_tls():
    s = socket.create_connection(("127.0.0.1", PORT), timeout=8)
    s.sendall(f"CONNECT {HOST}:443 HTTP/1.1\r\nHost: {HOST}:443\r\n\r\n".encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    assert buf.startswith(b"HTTP/1.1 200"), buf[:80]
    return ctx.wrap_socket(s, server_hostname=HOST)


tls0 = new_tls()
print("tls:", tls0.version(), "| cipher:", tls0.cipher()[0])
cert = tls0.getpeercert()
print("leaf subject:", dict(x[0] for x in cert["subject"]))
print("leaf issuer :", dict(x[0] for x in cert["issuer"]))
tls0.close()


def call(label, method, path, headers, body=b""):
    tls = new_tls()
    head = [f"{method} {path} HTTP/1.1", f"Host: {HOST}", "User-Agent: tesl-ca-probe",
            "Connection: close", "Accept: */*"]
    head += [f"{k}: {v}" for k, v in headers.items()]
    if body:
        head.append(f"Content-Length: {len(body)}")
    tls.sendall(("\r\n".join(head) + "\r\n\r\n").encode() + body)
    data = b""
    while True:
        chunk = tls.recv(65535)
        if not chunk:
            break
        data += chunk
    tls.close()
    head_raw, _, resp_body = data.partition(b"\r\n\r\n")
    status = head_raw.split(b"\r\n")[0].decode(errors="replace")
    checksum = ""
    for line in head_raw.decode(errors="replace").split("\r\n"):
        if line.lower().startswith("x-checksum:"):
            checksum = line.split(":", 1)[1].strip()
    print("-" * 62)
    print(f"{label}: {status} | X-Checksum={checksum or '-'}")
    print("  body:", resp_body.decode(errors="replace")[:220])


call("POST 正确请求", "POST", "/v1/feature_configuration",
     {"X-F50-Lab": "F50-LAB-MOCK-v1", "Content-Type": "application/json"}, b'{"vin":"PROBE"}')
call("GET  lab fixture", "GET", "/v1/feature-config", {"X-F50-Lab": "F50-LAB-MOCK-v1"})
call("POST 缺测试头", "POST", "/v1/feature_configuration",
     {"Content-Type": "application/json"}, b'{}')
