#!/bin/bash
# Assembles build/HalfLid.app from a release build and signs it ad hoc (no Apple Developer account needed).
#
#   scripts/make-app.sh              version 0.1.0
#   VERSION=0.2.0 scripts/make-app.sh
#
# Four executables live in the bundle: the resident menu bar app, the panel and the settings window (both started on demand,
# so nothing of them is in memory at rest), and `halflid`, which is also the guard process (`halflid guard`) and can be
# linked into a PATH folder to use it from a terminal. The settings window is a small application of its own, nested in
# Contents/Helpers, so that macOS lets it come to the front when it is opened from the menu bar.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP="build/HalfLid.app"
ICONSET="build/AppIcon.iconset"

scripts/build.sh >/dev/null

rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"
cp build/bin/HalfLidApp "$APP/Contents/MacOS/HalfLidApp"
cp build/bin/halflid "$APP/Contents/MacOS/halflid"
cp build/bin/HalfLidPanel "$APP/Contents/MacOS/HalfLidPanel"
cp -R Resources/i18n Resources/agent-marks Resources/agents.json "$APP/Contents/Resources/"
# Read by the About pane, and required by the licences of the artwork that is bundled.
cp NOTICE "$APP/Contents/Resources/NOTICE.txt"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

# The settings window is an application of its own (see SettingsLauncher), started through LaunchServices so that it can
# come to the front. It has its own identity; the menu bar app keeps the login item and the notification permission.
HELPER="$APP/Contents/Helpers/Half Lid Settings.app"
mkdir -p "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources"
cp build/bin/HalfLidSettings "$HELPER/Contents/MacOS/HalfLidSettings"

for SIZE in 16 32 128 256 512; do
  build/bin/halflid icon --kind app --size "$SIZE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png"
  build/bin/halflid icon --kind app --size "$((SIZE * 2))" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$APP/Contents/Resources/AppIcon.icns" "$HELPER/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# One entry per catalog, so the system treats the app as available in those languages (its own menus and dialogs follow).
LOCALIZATIONS=""
for FILE in Resources/i18n/*.json; do LOCALIZATIONS="${LOCALIZATIONS}<string>$(basename "$FILE" .json)</string>"; done

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LOCALIZATIONS}</array>
  <key>CFBundleExecutable</key><string>HalfLidApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>io.github.fedebartoli.halflid.menubar</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Half Lid</string>
  <key>CFBundleDisplayName</key><string>Half Lid</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright (c) 2026 fedebartoli. MIT License.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

cat > "$HELPER/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LOCALIZATIONS}</array>
  <key>CFBundleExecutable</key><string>HalfLidSettings</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>io.github.fedebartoli.halflid.settings</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Half Lid</string>
  <key>CFBundleDisplayName</key><string>Half Lid</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>Copyright (c) 2026 fedebartoli. MIT License.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP" 2>/dev/null
codesign --verify --deep --strict "$APP"
echo "Built $APP ($(du -sk "$APP" | cut -f1) KB, version $VERSION, ad-hoc signed)"
