"""局域网发现：UDP 触发 ARP + 读取邻居表，找车机。

用法: python tools/lan_scan.py 192.168.199
"""
import re
import socket
import subprocess
import sys
import time

prefix = sys.argv[1] if len(sys.argv) > 1 else "192.168.199"

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for i in range(1, 255):
    try:
        s.sendto(b"\x00", (f"{prefix}.{i}", 9))
    except OSError:
        pass
s.close()
time.sleep(1.2)

out = subprocess.run(["arp", "-a"], capture_output=True, text=True,
                     encoding="gbk", errors="replace").stdout
rows = []
for line in out.splitlines():
    m = re.match(r"\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F-]{17})\s+(\S+)", line)
    if m and m.group(1).startswith(prefix + "."):
        rows.append((m.group(1), m.group(2).lower(), m.group(3)))

for ip, mac, kind in sorted(rows, key=lambda r: int(r[0].split(".")[-1])):
    p = subprocess.run(["ping", "-n", "1", "-w", "500", ip], capture_output=True,
                       text=True, encoding="gbk", errors="replace")
    alive = "TTL=" in (p.stdout or "").upper()
    print(f"{ip:16} {mac}  {kind:10} {'alive' if alive else 'no-reply'}")
print(f"-- {len(rows)} 台设备")
