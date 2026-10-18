import json, sys
info = json.load(open(sys.argv[1]))
fs = info.get("formats", [])
def tbr(f): return f.get("tbr") or f.get("abr") or 0
print(f"{info.get('id')} {info.get('duration')}s clients/formats={len(fs)}")
for f in fs:
    if f.get("vcodec") in (None, "none") and f.get("acodec") in (None, "none"): continue
    size = f.get("filesize") or f.get("filesize_approx") or 0
    print(f"{f.get('format_id'):>12} {f.get('protocol'):<14} {f.get('ext'):<5} v={str(f.get('vcodec'))[:11]:<11} a={str(f.get('acodec'))[:9]:<9} h={f.get('height')} tbr={tbr(f):.0f} size={size/1e6:.0f}MB container={f.get('container')}")
# The app's choice (1.1.2): highest bitrate avc1/hevc MP4 video-only per height + best m4a/mp4a audio.
vids = [f for f in fs if f.get("acodec") == "none" and f.get("vcodec") not in (None, "none") and f.get("height")]
avf = [f for f in vids if f.get("ext") in ("mp4", "mov", "m4v") and str(f.get("vcodec")).startswith(("avc1", "hvc1", "hev1"))]
aud = [f for f in fs if f.get("vcodec") == "none" and f.get("acodec") not in (None, "none")]
m4a = [f for f in aud if f.get("ext") == "m4a" or str(f.get("acodec")).startswith("mp4a")]
best_a = max(m4a, key=tbr, default=None)
by_h = {}
for f in sorted(avf, key=tbr, reverse=True):
    by_h.setdefault(f["height"], f)
print("APP-CHOICE audio:", best_a and (best_a["format_id"], best_a.get("protocol")))
for h in sorted(by_h, reverse=True):
    print(f"APP-CHOICE {h}p:", by_h[h]["format_id"], by_h[h].get("protocol"))
if len(sys.argv) > 2:
    low = min(by_h) if by_h else None
    open(sys.argv[2], "w").write(f"{by_h[low]['format_id']} {best_a['format_id']}" if low and best_a else "")
