#!/bin/zsh
# Run the checks used by CI without launching the app or downloading a model.
set -eu
cd "${0:A:h:h}"

swift test --cache-path .build/package-cache
zsh scripts/build-app.sh
plutil -lint dist/Kotoba.app/Contents/Info.plist
codesign --verify --verbose dist/Kotoba.app
