#!/bin/bash
# Copies the shared extension sources into the per-browser folders (chrome/, firefox/).
set -euo pipefail
cd "$(dirname "$0")/../BrowserExtension"
VERSION="${VERSION:-$(cat ../VERSION)}"
for target in chrome firefox; do
  rm -rf "$target/icons"
  cp -R shared/icons "$target/icons"
  cp shared/*.js shared/*.html shared/*.css "$target/"
  # The extension carries the app's version, so the app can tell when the browser runs an older copy.
  python3 - "$target/manifest.json" "$VERSION" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
manifest = json.load(open(path))
manifest["version"] = version
open(path, "w").write(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
PY
done
echo "Extension synced to chrome/ and firefox/"
