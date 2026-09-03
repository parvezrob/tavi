#!/usr/bin/env bash
# House checks for the phone app: swiftformat decides layout, swiftlint
# decides size and safety. The gate can go red (#100): swiftlint runs
# --strict against a committed baseline of the warnings that were already
# there. Baselined violations are suppressed entirely — a clean run prints
# nothing but "lint: clean" — while any NEW warning, and every force unwrap
# or force try in Tavi/ (errors there), fails the run. A baselined entry
# also re-fires when the file's length changes, because file_length and
# type_body_length carry the exact count; re-record then, and the only diff
# in the baseline must be that count:
#   swiftlint lint --quiet --write-baseline .swiftlint-baseline.json
set -uo pipefail

cd "$(dirname "$0")/.."

for tool in swiftformat swiftlint; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "lint: $tool is not installed — run: brew install swiftformat swiftlint" >&2
        exit 127
    fi
done

status=0

echo "== swiftformat --lint =="
swiftformat --lint . || status=1

echo "== swiftlint =="
swiftlint lint --quiet --strict --baseline .swiftlint-baseline.json || status=1

if [ "$status" -ne 0 ]; then
    echo "lint: failed" >&2
else
    echo "lint: clean"
fi
exit "$status"
