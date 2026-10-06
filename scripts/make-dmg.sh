#!/bin/zsh
# Builds a Release "Deadline Progress Bars.app" and packages it into build/DeadlineProgressBars.dmg
set -euo pipefail

cd "${0:A:h}/.."

if command -v xcodegen >/dev/null; then
  xcodegen generate
fi

xcodebuild -project DeadlineProgress.xcodeproj -scheme DeadlineProgress \
  -configuration Release -derivedDataPath build clean build

rm -rf build/dmg build/DeadlineProgressBars.dmg
mkdir -p build/dmg
cp -R "build/Build/Products/Release/Deadline Progress Bars.app" build/dmg/
ln -s /Applications build/dmg/Applications

hdiutil create -volname "Deadline Progress Bars" -srcfolder build/dmg -ov -format UDZO build/DeadlineProgressBars.dmg

echo "Created: $PWD/build/DeadlineProgressBars.dmg"
