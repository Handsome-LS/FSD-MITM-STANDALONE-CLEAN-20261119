import pathlib

BOM = b"\xef\xbb\xbf"
for p in sorted(pathlib.Path(r"C:\fsd-mitm").glob("*.ps1")):
    b = p.read_bytes()
    if not b.startswith(BOM):
        p.write_bytes(BOM + b)
        print("bom added:", p.name)
    else:
        print("bom ok   :", p.name)
