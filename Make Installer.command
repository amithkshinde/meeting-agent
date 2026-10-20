#!/bin/bash
# Double-click this file to build an installer you can share (a single .dmg file).
cd "$(dirname "$0")"
echo "Building the installer. This builds for both Apple Silicon and Intel Macs and takes two to four minutes..."
echo
if scripts/make-installer.sh; then
  echo
  echo "Done. Opening the folder that holds your installer."
  open dist
else
  echo
  echo "Something went wrong. Copy the red text above and send it to Claude."
fi
echo
read -n 1 -s -r -p "Press any key to close this window."
