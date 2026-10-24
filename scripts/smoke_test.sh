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
# Browser integration: the local server must answer the extension and reject web pages.
PING=$(curl -s -m 5 http://127.0.0.1:9614/ping || true)
echo "ping: $PING"
EXT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 -X POST \
  -H "Content-Type: application/json" -H "Origin: chrome-extension://smoketest" \
  -d '{"url":"https://example.com/files/test.iso","fileName":"test.iso","referrer":"https://example.com/"}' \
  http://127.0.0.1:9614/download || true)
WEB_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 -X POST \
  -H "Content-Type: application/json" -H "Origin: https://evil.example" \
  -d '{"url":"https://example.com/x.iso"}' http://127.0.0.1:9614/download || true)
echo "extension POST: $EXT_CODE, web page POST: $WEB_CODE"
PREFLIGHT=$(curl -s -i -m 5 -X OPTIONS -H "Origin: chrome-extension://smoketest" \
  -H "Access-Control-Request-Method: POST" -H "Access-Control-Request-Private-Network: true" \
  http://127.0.0.1:9614/download || true)
if ! grep -q " 204" <<<"$PREFLIGHT" || ! grep -qi "Access-Control-Allow-Origin: chrome-extension://smoketest" <<<"$PREFLIGHT"; then
  echo "$PREFLIGHT" > preflight.txt
  annotate error "Browser integration preflight (CORS) check failed" preflight.txt
  STATUS=1
fi
if [[ "$PING" != *"MacOS Download Manager"* || "$EXT_CODE" != "200" || "$WEB_CODE" != "403" ]]; then
  echo "ping=$PING ext=$EXT_CODE web=$WEB_CODE" > bridge.txt
  annotate error "Browser integration server check failed" bridge.txt
  STATUS=1
fi

# The captured link opens the "Download File Info" dialog: the app must stay responsive.
sleep 5
if kill -0 "$PID" 2>/dev/null; then
  sample "$PID" 3 -file sample2.txt >/dev/null 2>&1
  python3 scripts/summarize_sample.py sample2.txt > main-thread2.txt
  if python3 scripts/summarize_sample.py --busy sample2.txt; then
    annotate error "Main thread busy after a captured download" main-thread2.txt
    STATUS=1
  else
    echo "Main thread idle after capture"
  fi
else
  tail -60 smoke.log > smoke-tail.txt
  annotate error "App exited after a captured download" smoke-tail.txt
  exit 1
fi

tail -40 smoke.log > smoke-tail.txt
[ -s smoke-tail.txt ] && annotate notice "App console output" smoke-tail.txt

kill "$PID" 2>/dev/null
sleep 1
kill -9 "$PID" 2>/dev/null
sleep 1

# Video tools started from inside the app, launched the way users launch it (Finder / LaunchServices):
# the app installs yt-dlp + Deno and runs them. Catches system-policy problems that only happen
# for programs started by the app (e.g. quarantine inherited by child processes).
REPORT="${RUNNER_TEMP:-/tmp}/mdm-selftest.txt"
rm -f "$REPORT"
if ! open --env "MDM_SELFTEST_YTDLP=$REPORT" "$APP" 2>/dev/null; then
  MDM_SELFTEST_YTDLP="$REPORT" "$BIN" > selftest.log 2>&1 &
fi
for i in $(seq 1 360); do [ -s "$REPORT" ] && break; sleep 1; done
echo "--- video tools self-test ---"
cat "$REPORT" 2>/dev/null || echo "(no report)"
if grep -q "^child-quarantine=yes" "$REPORT" 2>/dev/null; then
  # yt-dlp's Python library would be refused on Macs with Gatekeeper on (PYI "library load disallowed").
  annotate error "Files written by programs the app starts are quarantined" "$REPORT"
  STATUS=1
elif [ -s "$REPORT" ] && grep -q "^ytdlp-status=0" "$REPORT" && grep -q "^deno-status=0" "$REPORT" && grep -q "^ffmpeg-status=0" "$REPORT"; then
  annotate notice "Video tools run from inside the app" "$REPORT"
else
  [ -s "$REPORT" ] || echo "no report written within 360 s" > "$REPORT"
  annotate error "Video tools failed when started by the app" "$REPORT"
  STATUS=1
fi
pkill -x MacOSDownloadManager 2>/dev/null
sleep 2

# Quit from the Dock / ⌘Q keeps the app running in the menu bar; a quit request from another app
# (Finder replacing the app during an update, scripts) really quits it.
QREPORT="${RUNNER_TEMP:-/tmp}/mdm-quit.txt"
rm -f "$QREPORT"
open --env "MDM_SELFTEST_QUIT=$QREPORT" "$APP" 2>/dev/null || { MDM_SELFTEST_QUIT="$QREPORT" "$BIN" > quit.log 2>&1 & }
for i in $(seq 1 40); do [ -s "$QREPORT" ] && break; sleep 0.5; done
if [ -s "$QREPORT" ] && grep -q "^cmdq-still-running=yes" "$QREPORT" && grep -q "^policy-after-quit=accessory" "$QREPORT" \
   && grep -q "^windows-after-quit=0" "$QREPORT" && grep -q "^policy-after-reopen=regular" "$QREPORT"; then
  annotate notice "Quit keeps running in the menu bar" "$QREPORT"
else
  [ -s "$QREPORT" ] || echo "no report: the app probably quit on ⌘Q" > "$QREPORT"
  annotate error "Quit did not move the app to the menu bar" "$QREPORT"
  STATUS=1
fi
OUT=$(osascript -e 'tell application id "io.github.xuanthanhtnt.MacOSDownloadManager" to quit' 2>&1)
for i in $(seq 1 20); do pgrep -x MacOSDownloadManager >/dev/null || break; sleep 0.5; done
if ! pgrep -x MacOSDownloadManager >/dev/null; then
  echo "::notice title=Quit request from another app::the app quit (as needed for updates)"
elif echo "$OUT" | grep -q -- "-1743\|-600\|Not authori"; then
  echo "::notice title=Quit request from another app::not testable on this runner: $OUT"
else
  echo "::error title=Quit request from another app::the app kept running: $OUT"
  STATUS=1
fi
pkill -x MacOSDownloadManager 2>/dev/null
exit $STATUS
