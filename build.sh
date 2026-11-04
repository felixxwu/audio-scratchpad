#!/bin/zsh
# Builds AppRecorder.app without Xcode and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

app=build/AppRecorder.app
rm -rf build
mkdir -p "$app/Contents/MacOS"

swiftc=(/usr/bin/xcrun --sdk macosx swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0)

$swiftc Waveform.swift RecordingFile.swift WaveformCheck.swift -o build/waveform-check
build/waveform-check

$swiftc AppRecorder.swift Waveform.swift RecordingFile.swift -o "$app/Contents/MacOS/AppRecorder"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AppRecorder</string>
  <key>CFBundleIdentifier</key><string>com.felixwu.apprecorder</string>
  <key>CFBundleName</key><string>AppRecorder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"

mkdir -p ~/Applications
rm -rf ~/Applications/AppRecorder.app
cp -R "$app" ~/Applications/
echo "Installed to ~/Applications/AppRecorder.app"
