#!/usr/bin/env bash
#
# Lightweight, dependency-free repository hygiene checks. These run in CI after
# the build so a green build cannot hide the mistakes that are cheap to catch
# with text: large binaries in the tree, tracked build products, and the
# placeholder patterns this project explicitly forbids in shipping code.

set -uo pipefail

status=0
fail() { echo "::error::$1"; status=1; }
note() { echo "::notice::$1"; }

echo "== Large file check =="
while IFS= read -r file; do
  [ -f "$file" ] || continue
  size=$(wc -c < "$file" | tr -d ' ')
  if [ "$size" -gt 3145728 ]; then
    fail "Tracked file larger than 3 MB: $file ($size bytes). Media fixtures must be generated, not committed."
  fi
done < <(git ls-files)

echo "== Build product check =="
if git ls-files | grep -E '(^|/)(DerivedData|build)/' >/dev/null 2>&1; then
  fail "Build products are tracked in git."
fi

echo "== Placeholder check =="
# "Coming soon" UI and stub returns are banned in shipping sources (Frames/),
# though tests and documentation may mention them.
if grep -rniE 'coming soon|not implemented yet|TODO: implement' Frames/ --include='*.swift' >/dev/null 2>&1; then
  grep -rniE 'coming soon|not implemented yet|TODO: implement' Frames/ --include='*.swift' || true
  fail "Placeholder UI or stubs found in Frames/."
fi

echo "== Localization check =="
if [ ! -f Frames/Resources/Localizable.xcstrings ]; then
  fail "Missing string catalog at Frames/Resources/Localizable.xcstrings."
else
  if ! python3 -c "import json,sys; json.load(open('Frames/Resources/Localizable.xcstrings'))"; then
    fail "Localizable.xcstrings is not valid JSON."
  fi
fi

echo "== Asset catalog check =="
for required in \
  Frames/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json \
  Frames/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png \
  Frames/Resources/Assets.xcassets/AccentColor.colorset/Contents.json
do
  [ -f "$required" ] || fail "Missing required asset: $required"
done

echo "== Swift source inventory =="
count=$(git ls-files 'Frames/**/*.swift' | wc -l | tr -d ' ')
note "Swift sources in app target: $count"

exit $status
