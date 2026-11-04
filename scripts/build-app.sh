#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p .build/ModuleCache dist/Kotoba.app/Contents/MacOS dist/Kotoba.app/Contents/Resources
swift build --configuration release --cache-path .build/package-cache -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/ModuleCache"
cp .build/release/Kotoba dist/Kotoba.app/Contents/MacOS/Kotoba
cp Resources/Info.plist dist/Kotoba.app/Contents/Info.plist
codesign --force --sign - --identifier jp.kipeo.kotoba.local dist/Kotoba.app
printf 'Built: %s/dist/Kotoba.app\n' "$PWD"
