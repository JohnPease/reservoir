#!/bin/bash
# Runs the Reservoir test suite in the background with a PID file and a live log,
# so `scripts/test-status.sh` can answer "is it actually running, and did it pass?"
# without guessing from `ps aux` or re-running xcodebuild blind.
#
# Usage:
#   scripts/run-tests.sh                          # full ReservoirTests + ReservoirUITests
#   scripts/run-tests.sh -only-testing:ReservoirTests/FillGaugeCalculatorTests
#   DESTINATION_ID=<sim-udid> scripts/run-tests.sh
#
# Why this exists: `xcodebuild test` on this machine has known CoreSimulatorService
# flakiness (see project memory) where the process silently stalls with no further
# CPU time and no output, indistinguishable from "still working" until someone thinks
# to check `ps aux`. Backgrounding it bare loses the exit code and leaves no record of
# whether it was ever actually running. This script fixes both: it records a PID, a
# start timestamp, and streams output to a log file `test-status.sh` can inspect.

set -euo pipefail
cd "$(dirname "$0")/.."

RUN_DIR=".build/test-runs"
mkdir -p "$RUN_DIR"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$RUN_DIR/$RUN_ID.log"
PID_FILE="$RUN_DIR/current.pid"
META_FILE="$RUN_DIR/current.json"

DESTINATION_ID="${DESTINATION_ID:-}"
if [ -z "$DESTINATION_ID" ]; then
  # Prefer a simulator that's already booted (avoids paying simulator-boot time,
  # which is where CoreSimulatorService flakiness tends to bite).
  DESTINATION_ID="$(xcrun simctl list devices booted -j 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; ids=[dev["udid"] for runtime in d.values() for dev in runtime if dev.get("state")=="Booted"]; print(ids[0] if ids else "")' 2>/dev/null || true)"
fi
if [ -z "$DESTINATION_ID" ]; then
  echo "No booted simulator found and DESTINATION_ID not set. Boot one first, e.g.:" >&2
  echo "  xcrun simctl boot <udid> && open -a Simulator" >&2
  exit 1
fi

xcodegen generate >/dev/null 2>&1 || true

echo "Starting test run $RUN_ID against simulator $DESTINATION_ID"
echo "  log:  $LOG_FILE"
echo "  meta: $META_FILE"

nohup xcodebuild -project Reservoir.xcodeproj -scheme Reservoir \
  -destination "id=$DESTINATION_ID" test "$@" \
  > "$LOG_FILE" 2>&1 &
PID=$!

echo "$PID" > "$PID_FILE"
cat > "$META_FILE" <<EOF
{
  "runId": "$RUN_ID",
  "pid": $PID,
  "startedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "startedAtEpoch": $(date +%s),
  "destinationId": "$DESTINATION_ID",
  "logFile": "$LOG_FILE",
  "args": "$*"
}
EOF

echo "Started as PID $PID. Check progress with: scripts/test-status.sh"
