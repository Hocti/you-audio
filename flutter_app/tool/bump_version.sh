#!/usr/bin/env bash
# Bump the app version in pubspec.yaml: patch +1 and build number +1.
#
#   version: 1.0.2+5   ->   version: 1.0.3+6
#
# The part after `+` is the Android versionCode, which build.gradle reads via
# `flutter.versionCode`. Android refuses to replace an installed app with a
# lower versionCode (INSTALL_FAILED_VERSION_DOWNGRADE), so it must only ever
# go up — that is the whole reason this script exists instead of hand-editing.
set -euo pipefail

cd "$(dirname "$0")/.."
pubspec=pubspec.yaml

current=$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$pubspec" | head -1)
if [ -z "$current" ]; then
  echo "bump_version: 喺 $pubspec 搵唔到 'version:' 那行" >&2
  exit 1
fi

if ! printf '%s' "$current" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$'; then
  echo "bump_version: version 要係 X.Y.Z+N 格式，實際係 '$current'" >&2
  echo "              手動改好 $pubspec 再跑一次。" >&2
  exit 1
fi

name=${current%%+*}
build=${current##*+}
major=${name%%.*}
rest=${name#*.}
minor=${rest%%.*}
patch=${rest##*.}

next="${major}.${minor}.$((patch + 1))+$((build + 1))"

# Write via a temp file so a failed sed can't truncate pubspec.yaml.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
sed "s|^version:.*|version: ${next}|" "$pubspec" > "$tmp"
mv "$tmp" "$pubspec"
trap - EXIT

echo "version: ${current}  ->  ${next}"
