#!/bin/bash
# Builds the app and puts it in /Applications. Quit the running app first.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
rm -rf /Applications/SearchBetter.app
cp -R build.noindex/SearchBetter.app /Applications/
touch /Applications/SearchBetter.app
echo "installed /Applications/SearchBetter.app"
