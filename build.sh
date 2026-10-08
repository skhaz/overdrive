#!/bin/sh
set -e
VERSION=${GITHUB_REF_NAME#v}
swift build -c release
APP=Overdrive.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Overdrive "$APP/Contents/MacOS/"
xcrun actool Overdrive.icon --compile "$APP/Contents/Resources" --app-icon Overdrive --platform macosx --target-device mac --minimum-deployment-target 27.0 --output-partial-info-plist /dev/null >/dev/null
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Overdrive</string>
  <key>CFBundleIconFile</key><string>Overdrive</string>
  <key>CFBundleIconName</key><string>Overdrive</string>
  <key>CFBundleIdentifier</key><string>org.delduca.Overdrive</string>
  <key>CFBundleName</key><string>Overdrive</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-0.0.0}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>LastFMKey</key><string>${LASTFM_KEY:-}</string>
  <key>LastFMSecret</key><string>${LASTFM_SECRET:-}</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
