import struct, sys
def boxes(f, end, depth, out, limit=12):
    n = 0
    while f.tell() < end and n < limit:
        start = f.tell()
        hdr = f.read(8)
        if len(hdr) < 8: break
        size, typ = struct.unpack(">I4s", hdr)
        if size == 1: size = struct.unpack(">Q", f.read(8))[0]
        elif size == 0: size = end - start
        typ = typ.decode("latin1")
        extra = ""
        if typ == "ftyp":
            data = f.read(size - 8)
            extra = " " + data[:4].decode("latin1") + " [" + ",".join(data[i:i+4].decode("latin1") for i in range(8, len(data), 4)) + "]"
        out.append("  " * depth + typ + extra)
        if typ in ("moov", "trak", "mdia", "minf", "stbl", "mvex", "moof", "traf") and depth < 4:
            f.seek(start + 8)
            boxes(f, start + size, depth + 1, out, 20)
        f.seek(start + size)
        n += 1
for p in sys.argv[1:]:
    with open(p, "rb") as f:
        f.seek(0, 2); end = f.tell(); f.seek(0)
        out = []
        boxes(f, end, 0, out)
        print(p.split("/")[-1] + ": " + " / ".join(o.strip() for o in out[:40]))
