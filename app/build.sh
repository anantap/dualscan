#!/bin/bash
# Builds "Dual Scan.app" into app/build/.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f ../sane/lib/libsane.dylib ]; then
  echo "The SANE driver is missing. Build it first (see README.md)."
  exit 1
fi

xcodegen generate --quiet
xcodebuild -project DualScan.xcodeproj -scheme DualScan -configuration Release \
  -derivedDataPath build/DerivedData -quiet build

rm -rf "build/Dual Scan.app"
cp -R "build/DerivedData/Build/Products/Release/Dual Scan.app" build/
echo "Built: app/build/Dual Scan.app"

# ./build.sh --install also puts it in /Applications
if [ "${1:-}" = "--install" ]; then
  pkill -f "Dual Scan.app/Contents/MacOS" || true
  rm -rf "/Applications/Dual Scan.app"
  ditto "build/Dual Scan.app" "/Applications/Dual Scan.app"
  echo "Installed: /Applications/Dual Scan.app"
fi
