.PHONY: build run clean release dmg install uninstall test

# Build debug version
build:
	swift build

# Build and run
run: build
	.build/debug/MacRunner

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build build

# Build release version
release:
	swift build -c release --arch arm64 --arch x86_64

# Create app bundle
app: release
	@echo "Creating app bundle..."
	@mkdir -p build/MacRunner.app/Contents/MacOS
	@mkdir -p build/MacRunner.app/Contents/Resources
	@cp .build/release/MacRunner build/MacRunner.app/Contents/MacOS/
	@./scripts/generate-info-plist.sh > build/MacRunner.app/Contents/Info.plist
	@echo "App bundle created at build/MacRunner.app"

# Create DMG
dmg: app
	@echo "Creating DMG..."
	@command -v create-dmg >/dev/null 2>&1 || brew install create-dmg
	@create-dmg \
		--volname "Mac Runner" \
		--window-pos 200 120 \
		--window-size 600 400 \
		--icon-size 100 \
		--icon "MacRunner.app" 175 120 \
		--hide-extension "MacRunner.app" \
		--app-drop-link 425 120 \
		"build/MacRunner.dmg" \
		"build/MacRunner.app" 2>/dev/null || \
	hdiutil create -volname "Mac Runner" -srcfolder build/MacRunner.app -ov -format UDZO "build/MacRunner.dmg"
	@echo "DMG created at build/MacRunner.dmg"

# Install to /Applications
install: app
	@echo "Installing Mac Runner..."
	@rm -rf /Applications/MacRunner.app
	@cp -r build/MacRunner.app /Applications/
	@echo "Installed to /Applications/MacRunner.app"
	@echo "Run: open /Applications/MacRunner.app"

# Uninstall
uninstall:
	@echo "Uninstalling Mac Runner..."
	@rm -rf /Applications/MacRunner.app
	@rm -rf ~/Library/Application\ Support/MacRunner
	@rm -rf ~/.mac-runner
	@rm -rf ~/Library/Caches/com.omniaura.mac-runner
	@rm -rf ~/Library/HTTPStorages/com.omniaura.mac-runner* ~/Library/HTTPStorages/mac-runner* ~/Library/HTTPStorages/MacRunner*
	@rm -rf "$$HOME/Library/Saved Application State/com.omniaura.mac-runner.savedState"
	@rm -f ~/Library/Preferences/com.omniaura.mac-runner.plist ~/Library/Preferences/mac-runner.plist
	@rm -f ~/Library/Application\ Support/CrashReporter/MacRunner_*.plist ~/Library/Application\ Support/CrashReporter/mac-runner_*.plist
	@rm -f ~/Library/Logs/DiagnosticReports/MacRunner-*.ips ~/Library/Logs/DiagnosticReports/mac-runner-*.ips
	@echo "Uninstalled"
	@echo ""
	@echo "Note: this is a blunt removal of the invoking user's files. It does not"
	@echo "deregister runners from GitHub, and does not reach workspaces owned by a"
	@echo "dedicated service user (mac-runner add --isolation user), which live under"
	@echo "/Users/<service-user> and need sudo to delete."
	@echo "For those, run 'mac-runner uninstall' first - it deregisters from GitHub and"
	@echo "removes service-user workspaces, preserving anything it does not recognise."

# Run tests
test:
	swift test

# Format code
format:
	swift-format format -i -r Sources Tests

# Lint
lint:
	swift-format lint -r Sources Tests

# Update dependencies
update:
	swift package update

# Show package info
info:
	swift package describe

# Generate Xcode project
xcode:
	swift package generate-xcodeproj
	open MacRunner.xcodeproj
