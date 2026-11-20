#!/bin/zsh
# Build a Release LocalFlow.app (ad-hoc signed) and wrap it in dist/LocalFlow.dmg for GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")/.."
(cd App && xcodegen generate -q && xcodebuild -project LocalFlow.xcodeproj -scheme LocalFlow -configuration Release \
  -derivedDataPath ../.xcbuild -destination 'platform=macOS,arch=arm64' -skipMacroValidation -skipPackagePluginValidation \
  build > ../.xcbuild/build.log 2>&1) || { grep -E "error:" .xcbuild/build.log | head; echo "BUILD FAILED"; exit 1; }
rm -rf dist && mkdir -p dist/dmg
cp -R .xcbuild/Build/Products/Release/LocalFlow.app dist/dmg/
codesign --force --deep -s - dist/dmg/LocalFlow.app
ln -s /Applications dist/dmg/Applications
hdiutil create -volname LocalFlow -srcfolder dist/dmg -fs HFS+ -format UDZO -ov dist/LocalFlow.dmg >/dev/null
rm -rf dist/dmg
shasum -a 256 dist/LocalFlow.dmg
