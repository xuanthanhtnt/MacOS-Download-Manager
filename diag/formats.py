import json, sys
info = json.load(open(sys.argv[1]))
fs = info.get("formats", [])
def tbr(f): return f.get("tbr") or f.get("abr") or 0
vids = [f for f in fs if f.get("acodec") == "none" and f.get("vcodec") not in (None, "none") and f.get("height")]
avf = [f for f in vids if f.get("ext") in ("mp4", "mov", "m4v") and str(f.get("vcodec")).startswith(("avc1", "hvc1", "hev1"))]
aud = [f for f in fs if f.get("vcodec") == "none" and f.get("acodec") not in (None, "none")]
m4a = [f for f in aud if f.get("ext") == "m4a" or str(f.get("acodec")).startswith("mp4a")]
muxed = [f for f in fs if f.get("vcodec") not in (None, "none") and f.get("acodec") not in (None, "none")]
best_a = max(m4a, key=tbr, default=None)
by_h = {}
for f in sorted(avf, key=tbr, reverse=True):
    by_h.setdefault(f["height"], f)
lines = [f"{info.get('id')} {info.get('duration')}s formats={len(fs)}"]
lines.append("APP-CHOICE audio: %s" % (best_a and f"{best_a['format_id']} {best_a.get('protocol')}"))
for h in sorted(by_h, reverse=True):
    lines.append(f"APP-CHOICE {h}p: {by_h[h]['format_id']} {by_h[h].get('protocol')} tbr={tbr(by_h[h]):.0f}")
lines.append("-- avc1 video-only:")
for f in sorted(avf, key=lambda f: (f["height"], tbr(f))):
    lines.append(f"{f.get('format_id')} {f.get('protocol')} {f.get('ext')} {str(f.get('vcodec'))[:11]} {f.get('height')}p tbr={tbr(f):.0f}")
lines.append("-- m4a/mp4a audio:")
for f in m4a:
    lines.append(f"{f.get('format_id')} {f.get('protocol')} {f.get('ext')} {f.get('acodec')} tbr={tbr(f):.0f} container={f.get('container')}")
lines.append("-- muxed:")
for f in muxed:
    lines.append(f"{f.get('format_id')} {f.get('protocol')} {f.get('ext')} {str(f.get('vcodec'))[:11]}+{str(f.get('acodec'))[:9]} {f.get('height')}p tbr={tbr(f):.0f}")
print("\n".join(lines))
if len(sys.argv) > 2:
    low = min(by_h) if by_h else None
    open(sys.argv[2], "w").write(f"{by_h[low]['format_id']} {best_a['format_id']}" if low and best_a else "")
