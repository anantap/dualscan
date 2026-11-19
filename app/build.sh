#!/bin/bash
# Builds "Dual Scan III.app" into app/build/, with the SANE driver inside it.
# BUILD_NUMBER sets the build (GitHub uses its run number; the app updates itself to newer builds).
set -euo pipefail
cd "$(dirname "$0")"

command -v xcodegen >/dev/null 2>&1 || { echo "XcodeGen is missing. Install it with:  brew install xcodegen"; exit 1; }
../scripts/build-sane.sh

xcodegen generate --quiet
xcodebuild -project DualScan.xcodeproj -scheme DualScan -configuration Release \
  -derivedDataPath build/DerivedData -quiet build CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}"

rm -rf "build/Dual Scan III.app"
cp -R "build/DerivedData/Build/Products/Release/Dual Scan III.app" build/
echo "Built: app/build/Dual Scan III.app (build ${BUILD_NUMBER:-1})"

# ./build.sh --install also puts it in /Applications
if [ "${1:-}" = "--install" ]; then
  pkill -f "Dual Scan III.app/Contents/MacOS" || true
  rm -rf "/Applications/Dual Scan III.app"
  ditto "build/Dual Scan III.app" "/Applications/Dual Scan III.app"
  echo "Installed: /Applications/Dual Scan III.app"
fi
