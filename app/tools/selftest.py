"""通过代理访问 https://api-prd.../feature_configuration，
用 emSign 根证书校验证书链（模拟车机自带的公共信任库），验证：
  1) mitmproxy 返回 282 字节 mock；
  2) 证书链能靠 emSign 根 + 服务端下发的中间证书构建成功（无需在客户端装 CA）。

环境变量：
  SELFTEST_PORT    代理端口，默认 8080
  SELFTEST_CAFILE  信任根，默认 C:\\fsd-mitm\\certs\\3-root-emsign-ecc-g3.pem
"""
import os
import socket
import ssl
import sys

PORT = int(os.environ.get("SELFTEST_PORT", "8080"))
PROXY = ("127.0.0.1", PORT)
HOST = "api-prd.vn.cloud.tesla.cn"
PATH = "/mothership/vehicles/TESTVIN/feature_configuration"
CAFILE = os.environ.get("SELFTEST_CAFILE", r"C:\fsd-mitm\certs\3-root-emsign-ecc-g3.pem")

raw = socket.create_connection(PROXY, timeout=10)
raw.sendall(f"CONNECT {HOST}:443 HTTP/1.1\r\nHost: {HOST}:443\r\n\r\n".encode())
buf = b""
while b"\r\n\r\n" not in buf:
    buf += raw.recv(4096)
print("proxy:", buf.split(b"\r\n")[0].decode())

ctx = ssl.create_default_context(cafile=CAFILE)
ctx.check_hostname = True
ctx.verify_mode = ssl.CERT_REQUIRED
tls = ctx.wrap_socket(raw, server_hostname=HOST)
print("tls ok:", tls.version(), "| cipher:", tls.cipher()[0])
cert = tls.getpeercert()
print("subject:", dict(x[0] for x in cert["subject"]))
print("issuer :", dict(x[0] for x in cert["issuer"]))
print("SAN    :", cert.get("subjectAltName"))

tls.sendall(
    f"GET {PATH} HTTP/1.1\r\nHost: {HOST}\r\nUser-Agent: fsd-selftest\r\nConnection: close\r\n\r\n".encode()
)
resp = b""
while True:
    chunk = tls.recv(65535)
    if not chunk:
        break
    resp += chunk
head, _, body = resp.partition(b"\r\n\r\n")
print(head.decode(errors="replace"))
print("body bytes:", len(body))
print("body:", body.decode(errors="replace"))

ok = b"X-Checksum: 104ccde7d817ab00667f2d98326259ec" in head and len(body) == 282
sys.exit(0 if ok else 1)
