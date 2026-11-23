#!/bin/bash
# Builds Reservoir for JP's phone, installs it and launches it.
#
# Usage:
#   scripts/install-on-phone.sh
#   DEVICE_ID=<udid> scripts/install-on-phone.sh
#
# The build goes to .build/device so it never touches the simulator's derived data. The old
# Frameworks folder inside the built app is removed first: a stale one makes the install fail
# with a signing error (see project memory). Deleting only that fixed path here, rather than
# running `rm -rf` ad hoc, is what lets this script be allowed without allowing arbitrary deletes.

set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE_ID="${DEVICE_ID:-00008160-001470D10CA0000A}"
TEAM="${DEVELOPMENT_TEAM:-H7B8E54884}"
BUNDLE_ID="com.johnpease.Reservoir"
DERIVED=".build/device"
APP="$DERIVED/Build/Products/Debug-iphoneos/Reservoir.app"

rm -rf "$APP/Frameworks"

xcodegen generate >/dev/null
xcodebuild build -project Reservoir.xcodeproj -scheme Reservoir \
  -destination "id=$DEVICE_ID" DEVELOPMENT_TEAM="$TEAM" \
  -allowProvisioningUpdates -derivedDataPath "$DERIVED" 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[ -d "$APP" ] || { echo "build produced no app" >&2; exit 1; }

xcrun devicectl device install app --device "$DEVICE_ID" "$APP" 2>&1 | tail -1
xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID" 2>&1 | tail -1
