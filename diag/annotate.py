import sys
title, path = sys.argv[1], sys.argv[2]
text = open(path, errors="replace").read().strip() or "(empty)"
chunks, cur = [], ""
for line in text.split("\n"):
    if len(cur) + len(line) > 3000:
        chunks.append(cur); cur = ""
    cur += line + "\n"
chunks.append(cur)
for i, c in enumerate(chunks[:4]):
    print(f"::notice title={title} {i+1}::" + c.strip().replace("%", "%25").replace("\n", "%0A"))
