#!/bin/zsh
set -euo pipefail

ROOT="${CAPSULE_ROOT:-${0:A:h:h}}"
VERSION="${1:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  echo "Expected <major>.<minor>.<patch>[-prerelease], got '${VERSION:-<empty>}'." >&2
  exit 1
fi

# CFBundleShortVersionString must remain three period-separated integers.
# CapsuleReleaseVersion and the CLI carry the complete prerelease identity.
MARKETING_VERSION="${VERSION%%-*}"
CLI_SOURCE="$ROOT/Sources/CapsuleCLI/CapsuleCommand.swift"
PROJECT_SPEC="$ROOT/App/project.yml"

test -f "$CLI_SOURCE"
test -f "$PROJECT_SPEC"
test -f "$ROOT/VERSION"

/usr/bin/sed -E -i '' \
  "s/(version: \")[^\"]+(\",)/\\1${VERSION}\\2/" \
  "$CLI_SOURCE"
/usr/bin/sed -E -i '' \
  "s/(MARKETING_VERSION: \")[^\"]+(\")/\\1${MARKETING_VERSION}\\2/" \
  "$PROJECT_SPEC"
/usr/bin/sed -E -i '' \
  "s/(CAPSULE_RELEASE_VERSION: \")[^\"]+(\")/\\1${VERSION}\\2/" \
  "$PROJECT_SPEC"
printf '%s\n' "$VERSION" > "$ROOT/VERSION"

/usr/bin/grep -F "version: \"$VERSION\"," "$CLI_SOURCE" >/dev/null
/usr/bin/grep -F "MARKETING_VERSION: \"$MARKETING_VERSION\"" "$PROJECT_SPEC" >/dev/null
/usr/bin/grep -F "CAPSULE_RELEASE_VERSION: \"$VERSION\"" "$PROJECT_SPEC" >/dev/null
[[ "$(<"$ROOT/VERSION")" == "$VERSION" ]]

echo "Stamped Capsule $VERSION (bundle marketing version $MARKETING_VERSION)."
