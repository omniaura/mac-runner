# Mac Runner

Simple Mac menu bar app and CLI for managing GitHub Actions self-hosted runners.

## Features

- 🏃 Run multiple GitHub Actions runners on a single Mac
- 🖥️ **Dual CLI + GUI** — manage runners from terminal or menu bar
- 🔑 **`gh` CLI integration** — no manual PAT tokens, uses your existing `gh auth`
- 🔒 **Hybrid isolation** — choose user isolation (macOS runners) or container isolation (Linux workflows)
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

### Unsigned Binary

Mac Runner is not code-signed yet. macOS Gatekeeper will block the first launch. To allow it:

```bash
xattr -cr /Applications/MacRunner.app
```

Or: right-click the app → Open → click "Open" in the dialog.

### Prerequisites

- macOS 13+ (macOS 15+ for user isolation, macOS 26+ for container isolation)
- [`gh` CLI](https://cli.github.com/) installed and authenticated (`gh auth login`)
- Apple Silicon Mac (for container isolation)

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
      - name: Select runner
        id: runner
        uses: mikehardy/runner-fallback-action@v1
        with:
          primary-runner: mac-runner
          fallback-runner: macos-latest
          fallback-on-error: true
          github-token: ${{ secrets.RUNNER_TOKEN }}

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

### Token Setup

The runner-fallback-action queries the GitHub REST API to check runner availability. This requires a token with admin read access — the default `GITHUB_TOKEN` does not have this permission.

1. Create a [fine-grained Personal Access Token](https://github.com/settings/personal-access-tokens/new):
   - **Repository access:** select "Only select repositories" and pick your repo
   - **Permissions → Repository → Administration:** Read-only
2. Add it as a repository secret named `RUNNER_TOKEN`:
   ```bash
   gh secret set RUNNER_TOKEN
   ```

> **Note:** If the token is missing or invalid, `fallback-on-error: true` ensures the workflow still runs — it just falls back to cloud runners.

### References

- [`mikehardy/runner-fallback-action`](https://github.com/mikehardy/runner-fallback-action) — runner availability checker
- [`jimmygchen/runner-fallback-action`](https://github.com/jimmygchen/runner-fallback-action) — original (archived)
- [GitHub Community: Auto-switch to GitHub runner if self-hosted unavailable](https://github.com/orgs/community/discussions/20019)

## Isolation Modes

Mac Runner supports three isolation modes to protect your development environment:

### 1. No Isolation (Default)
- Runners execute directly as your current user
- Simple setup, works on any macOS version
- ⚠️ **Not recommended for untrusted workflows** — CI jobs have full access to your files

### 2. User Isolation (macOS 15+)
- Each runner runs as a dedicated system user (e.g., `_macrunner`)
- Prevents CI jobs from accessing your files, credentials, and desktop
- Best for macOS-based workflows
- **How to enable:**
  ```bash
  # CLI
  mac-runner add owner/repo --isolation user

  # GUI
  Settings → Isolation Mode → Dedicated User
  ```

### 3. Container Isolation (macOS 26+, Apple Silicon)
- Runs Linux workflows in isolated, lightweight virtual machines
- Uses Apple's [Containerization framework](https://github.com/apple/containerization)
- Sub-second startup times with Rosetta 2 for linux/amd64 emulation
- Best for Linux-based workflows, Docker builds, cross-platform testing
- **Requirements:** macOS 26+, Apple Silicon, Linux kernel 6.14.9+
- **How to enable:**
  ```bash
  # CLI
  mac-runner add owner/repo --isolation container

  # GUI
  Settings → Isolation Mode → Container
  ```

### Per-Runner Isolation Override

You can set a global default isolation mode and override it per-runner:

```bash
# Set global default to user isolation
mac-runner settings --isolation user

# Add a Linux runner with container isolation
mac-runner add owner/linux-project --isolation container

# Add a macOS runner with no isolation (for trusted workflows)
mac-runner add owner/trusted-project --isolation none
```

In the GUI, each runner displays its isolation mode with an icon:
- 🔓 No isolation
- 👤 User isolation
- 📦 Container isolation

## Planned Features

- [ ] Auto-provision CI tools (node, npm, gh) in runner environments
- [ ] Automatic pause when battery low
- [ ] Pause during specific hours
- [ ] Resource usage monitoring
- [ ] Notifications for job starts
- [ ] Custom container images for containerized runners

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
