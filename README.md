# Mac Runner

Simple Mac menu bar app for managing GitHub Actions self-hosted runners.

## Features

- 🏃 Run multiple GitHub Actions runners on a single Mac
- ⏸️ Pause/Resume all runners with one click
- 🎯 Perfect for when you need your Mac's resources for intensive work
- 📊 Monitor runner status from menu bar
- ⚡ Native Mac app, lightweight and fast

## Why?

GitHub Actions self-hosted runners are great, but:
- Official runner only supports one instance per machine
- No easy way to pause runners when you need CPU/memory
- Managing multiple repos means multiple runner processes
- No visual indication of runner status

**Mac Runner solves this.**

## How It Works

1. Install runners for your GitHub repos
2. Mac Runner manages them all from menu bar
3. Click "Pause All" when doing resource-intensive work
4. Click "Resume All" when ready to accept jobs again

## Architecture

- **Swift/SwiftUI** - Native Mac app
- **Menu Bar Interface** - Always accessible, minimal UI
- **Runner Management** - Start/stop/monitor runners
- **Persistent Config** - Remembers your runner setup

## Installation

### Homebrew

```bash
brew tap omniaura/tap https://github.com/omniaura/mac-runner
brew install --cask mac-runner
```

### Direct Download

Download the latest DMG from [Releases](https://github.com/omniaura/mac-runner/releases)

See [INSTALL.md](INSTALL.md) for detailed installation instructions.

## Setup

1. Launch Mac Runner from menu bar
2. Click "Add Runner"
3. Enter your GitHub PAT token and repo URL
4. Runner starts automatically!

See [INSTALL.md](INSTALL.md) for first-time setup guide.

## Features Coming Soon

- [ ] Automatic pause when battery low
- [ ] Pause during specific hours
- [ ] Per-repo enable/disable
- [ ] Resource usage monitoring
- [ ] Notifications for job starts
- [ ] Dark mode support

## Development

Built with:
- Swift 6
- SwiftUI
- AppKit (menu bar)
- GitHub Actions Runner API

## License

MIT
