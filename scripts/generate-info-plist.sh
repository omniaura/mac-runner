#!/bin/bash
# Generate Info.plist for Mac Runner

VERSION=${VERSION:-"0.1.0"}

cat << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacRunner</string>
    <key>CFBundleIdentifier</key>
    <string>com.omniaura.mac-runner</string>
    <key>CFBundleName</key>
    <string>Mac Runner</string>
    <key>CFBundleDisplayName</key>
    <string>Mac Runner</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Omni Aura. MIT License.</string>
</dict>
</plist>
EOF
