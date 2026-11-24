#!/bin/bash
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d)
cd "$W"
cp "$SRC/main.m" .
cp "$SRC/AppIcon.icns" .
APP="Coffee Buzz ARM.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"
clang -Os -fobjc-arc -arch arm64 -mmacosx-version-min=13.0 -Wl,-dead_strip main.m -o "$APP/Contents/MacOS/CoffeeBuzzARM" -framework Cocoa -framework IOKit -framework ServiceManagement -framework UserNotifications
strip -x "$APP/Contents/MacOS/CoffeeBuzzARM"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CoffeeBuzzARM</string>
<key>CFBundleIdentifier</key><string>local.self.CoffeeBuzzARM</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>Coffee Buzz ARM</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHumanReadableCopyright</key><string>Personal use</string>
</dict></plist>
P
codesign --force --sign - "$APP"
xattr -cr "$APP"
rm -rf "$SRC/$APP"
ditto --norsrc --noextattr "$APP" "$SRC/$APP"
echo "OK: $SRC/$APP"
