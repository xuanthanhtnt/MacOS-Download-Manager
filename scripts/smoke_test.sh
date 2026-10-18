#!/bin/bash
# Launches the built app for a few seconds and checks that it starts and that the main thread
# is not stuck. On CI the condensed main-thread stack is reported as an annotation.
#   ./scripts/smoke_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."

APP="build/MacOS Download Manager.app"
BIN="$APP/Contents/MacOS/MacOSDownloadManager"
[ -x "$BIN" ] || { echo "::error::App binary not found: $BIN"; exit 1; }

annotate() { # level title file
  local body
  body=$(head -c 30000 "$3" | sed -e 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')
  echo "::$1 title=$2::$body"
}

"$BIN" > smoke.log 2>&1 &
PID=$!
sleep 12

if ! kill -0 "$PID" 2>/dev/null; then
  echo "App exited during launch"
  tail -60 smoke.log > smoke-tail.txt
  annotate error "App exited during launch" smoke-tail.txt
  exit 1
fi

CPU1=$(ps -o %cpu= -p "$PID" | tr -d ' ')
sample "$PID" 3 -file sample.txt >/dev/null 2>&1
CPU2=$(ps -o %cpu= -p "$PID" | tr -d ' ')
python3 scripts/summarize_sample.py sample.txt > main-thread.txt
echo "CPU: $CPU1% / $CPU2%"
cat main-thread.txt | head -80

STATUS=0
if python3 scripts/summarize_sample.py --busy sample.txt; then
  annotate error "Main thread busy (CPU ${CPU2}%)" main-thread.txt
  STATUS=1
else
  annotate notice "Main thread idle (CPU ${CPU2}%)" main-thread.txt
fi
tail -40 smoke.log > smoke-tail.txt
[ -s smoke-tail.txt ] && annotate notice "App console output" smoke-tail.txt

kill "$PID" 2>/dev/null
sleep 1
kill -9 "$PID" 2>/dev/null
exit $STATUS
