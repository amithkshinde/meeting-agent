#!/bin/bash
# Builds an installer you can send to someone else: dist/MeetingAgent-<version>-<chip>.dmg
# Run it on your Mac (double-click "Make Installer.command" in the project folder).
# Usage: scripts/make-installer.sh [signing identity]
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname)" != "Darwin" ]; then
  echo "This has to run on a Mac."
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
CHIP="universal"              # runs on Apple Silicon and Intel Macs
NAME="MeetingAgent-${VERSION}-${CHIP}"
DMG="dist/${NAME}.dmg"
STAGE="build/dmg"

# 1. Build and sign the app (uses the same "Meeting Agent Dev" certificate as your own builds).
UNIVERSAL=1 scripts/build-app.sh "$@"
ARCHS="$(lipo -archs build/MeetingAgent.app/Contents/MacOS/MeetingAgent)"
echo "Built for: $ARCHS"
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) ;;
  *) echo "The app was not built for both chips. Copy the text above and send it to Claude."; exit 1 ;;
esac

# 2. Lay out what the person will see when they open the disk image.
rm -rf "$STAGE"
mkdir -p "$STAGE" dist
ditto "build/MeetingAgent.app" "$STAGE/Meeting Agent.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
MEETING AGENT  -  INSTALL IN 3 STEPS

Works on Apple Silicon and Intel Macs running macOS 15 or later.
macOS 26 gives the best live transcript.


STEP 1.  Install
Drag "Meeting Agent" onto the "Applications" folder in this window.


STEP 2.  Open it the first time
macOS shows a warning because this app is shared directly with you and
is not from the App Store. It is safe to allow. You only do this once.

  a) Open your Applications folder and double-click Meeting Agent.
     A message says it can't be opened. Click "Done" (or "OK").
  b) Open System Settings > Privacy & Security.
     Scroll down to the Security section. You will see
     "Meeting Agent was blocked". Click "Open Anyway", type your Mac
     password, and click "Open Anyway" once more.

  Faster way: open the Terminal app, paste this line and press Return,
  then open Meeting Agent normally:

     xattr -dr com.apple.quarantine "/Applications/Meeting Agent.app"


STEP 3.  Follow the setup inside the app (about 3 minutes)
  - Allow Screen Recording, Microphone and Speech Recognition when
    macOS asks. The app tells you exactly what to click.
  - Connect the AI. The app walks you through it:
      * Google Gemini: free, takes about 2 minutes to get a key
      * Claude: pay as you go, best answers
      * This Mac: no key and no sign-up. Needs an Apple Silicon Mac
        with Apple Intelligence, so it is not available on Intel Macs


AFTER THAT
  - Find Meeting Agent in Launchpad or Spotlight (press Command + Space).
    It also lives in the menu bar at the top of your screen.
  - When you join a call (Meet, Teams, Zoom...) it offers to record.
  - Recordings, transcripts and summaries are saved in
    Movies > MeetingAgent. Audio and video never leave your Mac.
    Only text is sent to the AI you choose.
  - Always tell people on a call that you are recording.

TO REMOVE: drag Meeting Agent from Applications to the Bin.
TXT

# 3. Make the disk image and check it.
rm -f "$DMG"
hdiutil create -volname "Meeting Agent" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

echo
echo "Installer ready: $DMG  ($(du -h "$DMG" | cut -f1))"
echo "Send that one file. The READ ME FIRST.txt inside it tells the person what to do."
