# Mac Runner

Simple Mac menu bar app and CLI for managing GitHub Actions self-hosted runners.

## Features

- 🏃 Run multiple GitHub Actions runners on a single Mac
- 🖥️ **Dual CLI + GUI** — manage runners from terminal or menu bar
- 🔑 **`gh` CLI integration** — no manual PAT tokens, uses your existing `gh auth`
- ⏸️ Pause/Resume all runners with one click
- 🎯 Perfect for when you need your Mac's resources for intensive work
- 📊 Monitor runner status from menu bar
- ⚡ Native Mac app, lightweight and fast
- 🤖 **Fully automated setup** — downloads and configures runners automatically

## Why?

GitHub Actions self-hosted runners are great, but:
- Official runner only supports one instance per machine
- No easy way to pause runners when you need CPU/memory
- Managing multiple repos means multiple runner processes
- No visual indication of runner status

**Mac Runner solves this.**

## Installation

### Homebrew

```bash
brew tap omniaura/tap https://github.com/omniaura/mac-runner
brew install --cask mac-runner
```

### Direct Download

Download the latest DMG from [Releases](https://github.com/omniaura/mac-runner/releases)

### Prerequisites

- macOS 13+
- [`gh` CLI](https://cli.github.com/) installed and authenticated (`gh auth login`)

## Quick Start

### GUI

1. Launch Mac Runner — appears in menu bar
2. Click "Add Runner"
3. Browse your repos (fetched via `gh`), pick one
4. Runner downloads, configures, registers, and starts automatically

### CLI

```bash
# Check GitHub auth
mac-runner auth

# Add a runner (downloads, configures, starts in background)
mac-runner add owner/repo --name my-runner --labels macos,mac-runner

# List runners
mac-runner list

# Start/stop
mac-runner start my-runner
mac-runner stop my-runner

# Remove (also deletes from GitHub)
mac-runner remove my-runner

# Status summary
mac-runner status
```

Runners started via CLI persist in the background — they survive the terminal session. Stop and start them from any terminal or from the GUI.

## CI/CD: Self-Hosted Runner with Automatic Cloud Fallback

Mac Runner uses a pattern that automatically routes CI jobs to your self-hosted Mac when it's online, and falls back to GitHub-hosted cloud runners when it's not. This means pushes to main always build, regardless of whether your Mac is on.

### How It Works

The release workflow uses [`mikehardy/runner-fallback-action`](https://github.com/mikehardy/runner-fallback-action) to query the GitHub API for available self-hosted runners before the build job starts:

```yaml
jobs:
  preflight:
    runs-on: ubuntu-latest
    outputs:
      runner: ${{ steps.runner.outputs.use-runner }}
    steps:
      # Detect if self-hosted runner is online, fall back to cloud if not
      # https://github.com/mikehardy/runner-fallback-action
      - name: Select runner
        id: runner
        uses: mikehardy/runner-fallback-action@v1
        with:
          primary-runner: mac-runner
          fallback-runner: macos-latest
          fallback-on-error: true
          github-token: ${{ secrets.GITHUB_TOKEN }}

  build:
    needs: preflight
    runs-on: ${{ fromJson(needs.preflight.outputs.runner) }}
    steps:
      - run: echo "Running on the best available runner"
```

| Mac online | Runner used | Cost |
|---|---|---|
| Yes | `mac-runner` (self-hosted) | Free |
| No | `macos-latest` (cloud) | GitHub Actions minutes |

This pattern is useful for any project that wants fast, free self-hosted builds when available, with reliable cloud fallback. See the [community discussion](https://github.com/orgs/community/discussions/20019) for background on why this isn't built into GitHub Actions natively.

### References

- [`mikehardy/runner-fallback-action`](https://github.com/mikehardy/runner-fallback-action) — runner availability checker
- [`jimmygchen/runner-fallback-action`](https://github.com/jimmygchen/runner-fallback-action) — original (archived)
- [GitHub Community: Auto-switch to GitHub runner if self-hosted unavailable](https://github.com/orgs/community/discussions/20019)

## Architecture

- **Swift 6 / SwiftUI** — Native Mac app
- **Menu Bar Interface** — Always accessible, minimal UI
- **`gh` CLI** — All GitHub API calls go through `gh` (auth, repos, runner tokens, CRUD)
- **PID-based process management** — Runners persist across CLI sessions
- **Dual entry point** — `main.swift` dispatches to CLI handler or SwiftUI app

## Development

```bash
# Build
swift build

# Run CLI
.build/debug/mac-runner --help

# Run GUI (no args)
.build/debug/mac-runner

# Test
swift test
```

## Contributing

We use [Conventional Commits](https://www.conventionalcommits.org/) for automatic versioning:

- `feat:` — New feature (minor bump)
- `fix:` — Bug fix (patch bump)
- `chore:` — No release

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

## License

MIT
