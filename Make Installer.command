#!/bin/bash
# Double-click this file to build an installer you can share (a single .dmg file).
cd "$(dirname "$0")"
echo "Building the Apple Silicon installer. This takes a few minutes..."
echo
if ONLY_ARM64=1 scripts/make-installer.sh; then
  echo
  echo "Done. Opening the folder that holds your installer."
  open dist
else
  echo
  echo "Something went wrong. Copy the red text above and send it to Claude."
fi
echo
read -n 1 -s -r -p "Press any key to close this window."
