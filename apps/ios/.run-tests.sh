#!/usr/bin/env bash
cd /tmp/tavi-wt-111-p2-events/apps/ios
export TAVI_DERIVED_DATA=~/Library/Developer/Xcode/DerivedData/tavi-wt-111-p2-events
args=()
for c in "$@"; do args+=(-only-testing:"$c"); done
xcodebuild test -project Tavi.xcodeproj -scheme Tavi \
  -destination "id=8AA84E15-9F0B-4BBB-949B-CEAE9C24919F" \
  -derivedDataPath "$TAVI_DERIVED_DATA" CODE_SIGNING_ALLOWED=NO "${args[@]}" 2>&1 | tail -30
exit "${PIPESTATUS[0]}"
