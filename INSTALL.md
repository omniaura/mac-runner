# Installation

## Homebrew (Recommended)

```bash
# Add the tap
brew tap omniaura/tap https://github.com/omniaura/mac-runner

# Install Mac Runner
brew install --cask mac-runner

# Run it
open -a "Mac Runner"
```

## Direct Download

1. Download the latest DMG from [Releases](https://github.com/omniaura/mac-runner/releases)
2. Open the DMG
3. Drag Mac Runner to Applications
4. Launch from Applications folder

## Building from Source

### Requirements

- macOS 13+ (Ventura or later)
- Xcode 15+
- Swift 6

### Build

```bash
# Clone the repo
git clone https://github.com/omniaura/mac-runner.git
cd mac-runner

# Build release binary
swift build -c release

# Run
.build/release/MacRunner
```

### Create App Bundle

```bash
# Build for both architectures
swift build -c release --arch arm64 --arch x86_64

# Create app bundle
mkdir -p build/MacRunner.app/Contents/MacOS
cp .build/release/MacRunner build/MacRunner.app/Contents/MacOS/

# Copy Info.plist
cp Info.plist build/MacRunner.app/Contents/

# Run it
open build/MacRunner.app
```

## First-Time Setup

1. Launch Mac Runner
2. Click the runner icon in your menu bar
3. Click "Add Runner"
4. You'll need:
   - GitHub Personal Access Token (with `repo` scope)
   - Repository URL (format: `owner/repo`)
   - Runner name (optional)
   - Labels (optional, defaults to `macos`)

### Creating a GitHub Token

1. Go to https://github.com/settings/tokens
2. Click "Generate new token (classic)"
3. Give it a name: "Mac Runner"
4. Select scope: `repo` (Full control of private repositories)
5. Click "Generate token"
6. Copy the token (you won't see it again!)
7. Paste into Mac Runner

## Updating

### Homebrew

```bash
brew upgrade mac-runner
```

### Manual

Download the latest release and replace your existing installation.

## Uninstalling

### Homebrew

```bash
brew uninstall --cask mac-runner
```

### Manual

1. Quit Mac Runner
2. Delete from Applications folder
3. (Optional) Remove config and runners:
   ```bash
   rm -rf ~/Library/Application\ Support/MacRunner
   ```

## Troubleshooting

### "Mac Runner" cannot be opened

If you see a security warning on first launch:

1. Open System Preferences → Security & Privacy
2. Click "Open Anyway" for Mac Runner
3. Or right-click the app → Open → Open

### Runner won't start

Check that:
- Your GitHub token is valid and has `repo` scope
- The repository exists and you have access
- No other runner is using the same name

### High CPU usage

Runners can use significant CPU during builds. Use the "Pause All" button when you need your Mac's full resources.

## Auto-Start on Login

To run Mac Runner automatically when you log in:

1. Open System Preferences → Users & Groups
2. Click your username
3. Select Login Items
4. Click the + button
5. Navigate to Applications → Mac Runner
6. Click Add

Or enable in Mac Runner Settings (coming soon).
