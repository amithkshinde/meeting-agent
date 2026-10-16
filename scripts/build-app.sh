#!/bin/bash
# Builds MeetingAgent.app from the Swift package. Run on a Mac with Xcode or the Swift toolchain.
# Usage: scripts/build-app.sh [signing identity]
#   Default identity is "-" (ad-hoc). macOS forgets Screen Recording permission every time an
#   ad-hoc build changes. To keep it, create a self-signed "Meeting Agent Dev" certificate in
#   Keychain Access (Certificate Assistant > Create a Certificate > Code Signing) and pass its name.
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY="${1:--}"
APP="build/MeetingAgent.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/MeetingAgent" "$APP/Contents/MacOS/MeetingAgent"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" "$APP"

echo "Built $APP"
echo "Run it with: open $APP"
