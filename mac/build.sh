#!/bin/zsh
# Builds Audio Scratchpad.app without Xcode and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

# An optional version such as v1.2.0, stored in the app. Bundle versions can't hold a prerelease suffix such as -beta.1.
version="${1:-0.0.0}"
version="${version#v}"
version="${version%%[-+]*}"

app="../build/Audio Scratchpad.app"
rm -rf ../build
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

swiftc=(/usr/bin/xcrun --sdk macosx swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0)

$swiftc Waveform.swift RecordingFile.swift Quality.swift SelfCheck.swift -o ../build/self-check
../build/self-check

$swiftc AudioScratchpad.swift Recorder.swift Waveform.swift RecordingFile.swift Quality.swift -o "$app/Contents/MacOS/Audio Scratchpad"
# The quality check is shared with the web version, which serves the same file.
cp ../web/audio-quality.js "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Audio Scratchpad</string>
  <key>CFBundleIdentifier</key><string>com.felixwu.audioscratchpad</string>
  <key>CFBundleName</key><string>Audio Scratchpad</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"

mkdir -p ~/Applications
rm -rf ~/Applications/"Audio Scratchpad.app"
cp -R "$app" ~/Applications/
echo "Installed to ~/Applications/Audio Scratchpad.app"
