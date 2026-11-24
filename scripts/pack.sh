#!/bin/sh
# 🐱 Regenerate the Xcode project and pack this whole folder as dist/LivePTV.zip (to move it to another Mac through
# 🐱 iCloud Drive: a zip arrives complete, a synced folder can arrive half-downloaded). The root Package.swift (for
# 🐱 adding the repository by URL) is left out: the Xcode project uses LivePTVKit/ as its local package.
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; fi
[ -f LivePTV.xcodeproj/project.pbxproj ] || { echo "LivePTV.xcodeproj is missing: install XcodeGen (brew install xcodegen)"; exit 1; }
STAGE=$(mktemp -d)
rsync -a --exclude '.build/' --exclude '.swiftpm/' --exclude 'dist/' --exclude 'DerivedData/' --exclude 'xcuserdata/' \
  --exclude 'ace-probe-*/' --exclude '.DS_Store' --exclude '/Package.swift' --exclude '.github/' --exclude '.git/' ./ "$STAGE/LivePTV/"
mkdir -p dist
rm -f dist/LivePTV.zip
(cd "$STAGE" && ditto -c -k --norsrc --keepParent LivePTV "$ROOT/dist/LivePTV.zip")
rm -rf "$STAGE"
echo "created dist/LivePTV.zip"
