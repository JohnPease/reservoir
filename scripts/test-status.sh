#!/bin/bash
# Reports the real status of the most recent `scripts/run-tests.sh` run: still running
# (and whether it's making progress or stalled), or finished (and whether it passed).
# Never silently returns nothing — always prints a clear verdict.

set -uo pipefail
cd "$(dirname "$0")/.."

RUN_DIR=".build/test-runs"
PID_FILE="$RUN_DIR/current.pid"
META_FILE="$RUN_DIR/current.json"

STALL_THRESHOLD_SECONDS=90

if [ ! -f "$META_FILE" ]; then
  echo "No test run has been started with scripts/run-tests.sh yet."
  exit 1
fi

RUN_ID=$(/usr/bin/python3 -c 'import json; print(json.load(open("'"$META_FILE"'"))["runId"])')
LOG_FILE=$(/usr/bin/python3 -c 'import json; print(json.load(open("'"$META_FILE"'"))["logFile"])')
STARTED_EPOCH=$(/usr/bin/python3 -c 'import json; print(json.load(open("'"$META_FILE"'"))["startedAtEpoch"])')
PID=$(cat "$PID_FILE" 2>/dev/null || echo "")

NOW=$(date +%s)
ELAPSED=$((NOW - STARTED_EPOCH))

echo "Run: $RUN_ID  (started ${ELAPSED}s ago)"
echo "Log: $LOG_FILE"
echo

if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
  # Process has exited. Determine outcome from the log rather than assuming success.
  if [ ! -f "$LOG_FILE" ]; then
    echo "VERDICT: UNKNOWN — process is gone and no log file exists."
    exit 2
  fi
  if grep -q "\*\* TEST SUCCEEDED \*\*" "$LOG_FILE"; then
    PASS_COUNT=$(grep -oE "Executed [0-9]+ test" "$LOG_FILE" | tail -1 || true)
    echo "VERDICT: PASSED — ${PASS_COUNT:-tests completed}"
    exit 0
  elif grep -q "\*\* TEST FAILED \*\*" "$LOG_FILE"; then
    echo "VERDICT: FAILED — failing tests:"
    grep -E "^\s*.*error.*:|Test Case.*failed" "$LOG_FILE" | tail -20
    exit 1
  elif grep -q "\*\* BUILD FAILED \*\*" "$LOG_FILE"; then
    echo "VERDICT: BUILD FAILED (never got to running tests) — last errors:"
    grep -E "error:" "$LOG_FILE" | tail -20
    exit 1
  elif grep -q "BUILD INTERRUPTED" "$LOG_FILE"; then
    echo "VERDICT: INTERRUPTED — process died mid-run without a clear pass/fail result."
    echo "Last 20 log lines:"
    tail -20 "$LOG_FILE"
    exit 3
  else
    echo "VERDICT: UNKNOWN — process exited but no recognizable outcome marker in the log."
    echo "This usually means it was killed (e.g. CoreSimulatorService stall) rather than finishing."
    echo "Last 20 log lines:"
    tail -20 "$LOG_FILE"
    exit 3
  fi
fi

# Process is alive — check whether it's actually making progress or silently stuck.
LAST_MODIFIED=$(stat -f %m "$LOG_FILE" 2>/dev/null || echo "$NOW")
SINCE_LAST_OUTPUT=$((NOW - LAST_MODIFIED))

if [ "$SINCE_LAST_OUTPUT" -gt "$STALL_THRESHOLD_SECONDS" ]; then
  echo "VERDICT: RUNNING BUT LIKELY STALLED — PID $PID is alive but the log hasn't grown in ${SINCE_LAST_OUTPUT}s."
  echo "This matches known CoreSimulatorService flakiness on this machine. Consider killing (kill $PID) and retrying."
else
  echo "VERDICT: RUNNING — PID $PID alive, log updated ${SINCE_LAST_OUTPUT}s ago (still making progress)."
fi
echo "Last 10 log lines:"
tail -10 "$LOG_FILE"
