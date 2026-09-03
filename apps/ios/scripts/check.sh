#!/usr/bin/env bash
# The phone's gate, owner-run: lint, then a simulator build, then TaviTests,
# stopping at the first failure and exiting with its status. Why the phone
# has no hosted CI is in docs/DEVELOPMENT.md.
set -uo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "check: xcodebuild is not installed — install Xcode, then: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 127
fi

# The owner's simulator (docs/OWNER_ENVIRONMENT.md); override for another.
simulator="${TAVI_SIMULATOR_ID:-3CA94743-421A-4866-BD4F-2A92149AFE82}"
# Outside the tree so this run never shares state with Xcode's own build.
derived_data="${TAVI_DERIVED_DATA:-/tmp/tavi-check-derived-data}"

if ! xcrun simctl list devices | grep -q "$simulator"; then
    echo "check: no simulator with id $simulator — list them with: xcrun simctl list devices" >&2
    exit 1
fi

xcode() {
    xcodebuild "$@" \
        -project Tavi.xcodeproj \
        -scheme Tavi \
        -destination "platform=iOS Simulator,id=$simulator" \
        -derivedDataPath "$derived_data" \
        CODE_SIGNING_ALLOWED=NO
}

echo "== lint =="
./scripts/lint.sh || exit $?

echo "== build =="
xcode build || exit $?

# The live UI suites need the owner's Mac as a host and stay owner-run.
echo "== TaviTests =="
xcode test -only-testing:TaviTests || exit $?

echo "check: green"
