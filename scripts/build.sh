#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/build/Usage Monitor.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/UsageMonitor "$APP/Contents/MacOS/UsageMonitor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
