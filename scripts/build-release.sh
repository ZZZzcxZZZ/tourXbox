#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
xcodebuild -project tourXbox.xcodeproj -scheme tourXbox -configuration Release \
  -derivedDataPath .build-release ARCHS="${ARCHS:-arm64}" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build
app="$project_root/.build-release/Build/Products/Release/tourXbox.app"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Built: %s\n' "$app"
