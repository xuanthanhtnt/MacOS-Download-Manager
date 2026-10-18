#!/bin/bash
# Creates the files served by scripts/test_server.py for the integration tests.
#   ./scripts/test_fixtures.sh <dir>
set -euo pipefail
DIR="$1"
rm -rf "$DIR"
mkdir -p "$DIR/files" "$DIR/hls"

# 6 MB random file for multi-connection / resume tests
head -c 6000000 /dev/urandom > "$DIR/files/big.bin"

# HLS: 5 segments encrypted with AES-128 (IV derived from the media sequence number)
openssl rand 16 > "$DIR/hls/key.bin"
KEYHEX=$(od -An -tx1 "$DIR/hls/key.bin" | tr -d ' \n')
: > "$DIR/hls/plain-all.ts"
{
  echo "#EXTM3U"
  echo "#EXT-X-VERSION:3"
  echo "#EXT-X-TARGETDURATION:4"
  echo "#EXT-X-MEDIA-SEQUENCE:0"
  echo "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\""
} > "$DIR/hls/index.m3u8"
for i in 0 1 2 3 4; do
  head -c 150000 /dev/urandom > "$DIR/plain$i.bin"
  cat "$DIR/plain$i.bin" >> "$DIR/hls/plain-all.ts"
  IV=$(printf "%032x" "$i")
  openssl enc -aes-128-cbc -K "$KEYHEX" -iv "$IV" -in "$DIR/plain$i.bin" -out "$DIR/hls/seg$i.ts"
  echo "#EXTINF:4.0," >> "$DIR/hls/index.m3u8"
  echo "seg$i.ts" >> "$DIR/hls/index.m3u8"
done
echo "#EXT-X-ENDLIST" >> "$DIR/hls/index.m3u8"

# Master playlist pointing at the media playlist
cat > "$DIR/hls/master.m3u8" <<EOF
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360
index.m3u8
EOF
echo "fixtures ready in $DIR"
