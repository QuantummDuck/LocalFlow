#!/bin/zsh
# Build LocalFlow (Release), install to /Applications, and copy the models into place.
# usage: scripts/install.sh [model-dir] [fix-model-dir]   (default: bench/models/cleaner*, if you trained your own)
set -euo pipefail
cd "$(dirname "$0")/.."
MODEL=${1:-bench/models/cleaner}
FIX=${2:-bench/models/cleaner-fix}   # correction specialist, used only on chunks with a correction cue
(cd App && xcodegen generate -q && xcodebuild -project LocalFlow.xcodeproj -scheme LocalFlow -configuration Release \
  -derivedDataPath ../.xcbuild -destination 'platform=macOS,arch=arm64' -skipMacroValidation -skipPackagePluginValidation \
  build > ../.xcbuild/build.log 2>&1) || { grep -E "error:" .xcbuild/build.log | head; echo "BUILD FAILED (see .xcbuild/build.log)"; exit 1; }
SUPPORT="$HOME/Library/Application Support/LocalFlow"
mkdir -p "$SUPPORT/models"
if [[ -d "$MODEL" ]]; then rm -rf "$SUPPORT/models/cleaner"; cp -R "$MODEL" "$SUPPORT/models/cleaner"; fi
if [[ -d "$FIX" ]]; then rm -rf "$SUPPORT/models/cleaner-fix"; cp -R "$FIX" "$SUPPORT/models/cleaner-fix"; fi
# Models missing here are downloaded by the app on first launch.
pkill -x LocalFlow 2>/dev/null || true
rm -rf /Applications/LocalFlow.app
cp -R .xcbuild/Build/Products/Release/LocalFlow.app /Applications/
# Stable self-signed identity (separate keychain) so macOS keeps Accessibility/Mic grants across rebuilds.
KC="$SUPPORT/signing.keychain-db"
if [[ -f "$KC" ]]; then
  security unlock-keychain -p localflow-signing "$KC"
  codesign --force --deep --keychain "$KC" -s "LocalFlow Local Signing" /Applications/LocalFlow.app
else
  codesign --force --deep -s - /Applications/LocalFlow.app   # ad hoc: permissions reset on every rebuild
fi
codesign -dr - /Applications/LocalFlow.app 2>&1 | tail -1
echo "Installed /Applications/LocalFlow.app"
