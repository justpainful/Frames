#!/usr/bin/env bash
#
# Resolves an iOS 26 simulator destination for xcodebuild and writes it to
# $GITHUB_OUTPUT as `destination`.
#
# Preference order:
#   1. $PREFERRED_DEVICE on any iOS 26 runtime (default: iPhone 17 Pro)
#   2. any iPhone on an iOS 26 runtime
#   3. generic iOS Simulator platform destination (build-only fallback)
#
# GitHub's macOS images move device and runtime versions around between image
# releases, so pinning an exact "iPhone 17 Pro, OS=26.5" string makes CI fail for
# reasons unrelated to the code. We pin the *intent* and resolve the specifics.

set -euo pipefail

PREFERRED_DEVICE="${PREFERRED_DEVICE:-iPhone 17 Pro}"

pick() {
  # $1 = device name to match, or the sentinel "__any_iphone__".
  python3 - "$1" <<'PY'
import json, subprocess, sys

wanted = sys.argv[1]
data = json.loads(subprocess.run(
    ["xcrun", "simctl", "list", "devices", "available", "--json"],
    capture_output=True, text=True, check=True).stdout)

best = None
for runtime, devices in data.get("devices", {}).items():
    if "iOS-26" not in runtime:
        continue
    version = runtime.split("iOS-")[-1].replace("-", ".")
    try:
        key = tuple(int(part) for part in version.split("."))
    except ValueError:
        key = (0,)
    for device in devices:
        if not device.get("isAvailable", False):
            continue
        name = device.get("name", "")
        if wanted == "__any_iphone__":
            if not name.startswith("iPhone"):
                continue
        elif name != wanted:
            continue
        candidate = (key, name, device["udid"])
        if best is None or candidate[0] > best[0]:
            best = candidate

if best:
    print(best[2])
PY
}

udid="$(pick "$PREFERRED_DEVICE" || true)"
if [ -z "$udid" ]; then
  echo "::warning::'$PREFERRED_DEVICE' on iOS 26 not found; falling back to any iOS 26 iPhone."
  udid="$(pick "__any_iphone__" || true)"
fi

if [ -n "$udid" ]; then
  destination="platform=iOS Simulator,id=$udid"
  xcrun simctl list devices available | grep -i "$udid" || true
else
  echo "::warning::No iOS 26 iPhone simulator available; using the generic simulator destination."
  destination="generic/platform=iOS Simulator"
fi

echo "Resolved destination: $destination"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "destination=$destination" >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "**Destination:** \`$destination\`" >> "$GITHUB_STEP_SUMMARY"
fi
