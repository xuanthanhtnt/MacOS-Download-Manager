#!/bin/bash
# Copies the shared extension sources into the per-browser folders (chrome/, firefox/).
set -euo pipefail
cd "$(dirname "$0")/../BrowserExtension"
for target in chrome firefox; do
  rm -rf "$target/icons"
  cp -R shared/icons "$target/icons"
  cp shared/*.js shared/*.html shared/*.css "$target/"
done
echo "Extension synced to chrome/ and firefox/"
