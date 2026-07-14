#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/capsule-version-test.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

CURRENT_VERSION="$(<"$ROOT/VERSION")"
CURRENT_MARKETING_VERSION="${CURRENT_VERSION%%-*}"
grep -F "version: \"$CURRENT_VERSION\"," \
  "$ROOT/Sources/CapsuleCLI/CapsuleCommand.swift" >/dev/null
grep -F "MARKETING_VERSION: \"$CURRENT_MARKETING_VERSION\"" \
  "$ROOT/App/project.yml" >/dev/null
grep -F "CAPSULE_RELEASE_VERSION: \"$CURRENT_VERSION\"" \
  "$ROOT/App/project.yml" >/dev/null

mkdir -p "$FIXTURE/App" "$FIXTURE/Sources/CapsuleCLI"
cp "$ROOT/VERSION" "$FIXTURE/VERSION"
cp "$ROOT/App/project.yml" "$FIXTURE/App/project.yml"
cp "$ROOT/Sources/CapsuleCLI/CapsuleCommand.swift" \
  "$FIXTURE/Sources/CapsuleCLI/CapsuleCommand.swift"

CAPSULE_ROOT="$FIXTURE" "$ROOT/scripts/stamp-version.sh" "2.4.0-rc.1"

[[ "$(<"$FIXTURE/VERSION")" == "2.4.0-rc.1" ]]
grep -F 'version: "2.4.0-rc.1",' \
  "$FIXTURE/Sources/CapsuleCLI/CapsuleCommand.swift" >/dev/null
grep -F 'MARKETING_VERSION: "2.4.0"' "$FIXTURE/App/project.yml" >/dev/null
grep -F 'CAPSULE_RELEASE_VERSION: "2.4.0-rc.1"' \
  "$FIXTURE/App/project.yml" >/dev/null

if CAPSULE_ROOT="$FIXTURE" "$ROOT/scripts/stamp-version.sh" "not-semver" >/dev/null 2>&1; then
  echo "Invalid release versions must be rejected." >&2
  exit 1
fi

echo "Release version stamping accepts prereleases and rejects invalid versions."
