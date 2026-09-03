#!/usr/bin/env bash
# House checks for the phone app: swiftformat decides layout, swiftlint
# decides size and safety. Warnings are printed; only errors fail the run.
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
# --strict would promote warnings to errors; the recorded ones are for #69.
swiftlint lint --quiet || status=1

if [ "$status" -ne 0 ]; then
    echo "lint: failed" >&2
else
    echo "lint: clean (warnings above are recorded, not blocking)"
fi
exit "$status"
