# Mac Runner

Simple Mac menu bar app and CLI for managing GitHub Actions self-hosted runners.

## Features

- 🏃 Run multiple GitHub Actions runners on a single Mac
- 🖥️ **Dual CLI + GUI** — manage runners from terminal or menu bar
- 🔑 **`gh` CLI integration** — no manual PAT tokens, uses your existing `gh auth`
- 🔒 **Hybrid isolation** — choose user isolation (macOS runners) or container isolation (Linux workflows)
- 🎭 **Headless by default** — runners run without GUI access (enable when needed for visual testing)
- ⏸️ Pause/Resume all runners with one click
- 🎯 Perfect for when you need your Mac's resources for intensive work
- 📊 Monitor runner status from menu bar
- ⚡ Native Mac app, lightweight and fast
- 🤖 **Fully automated setup** — downloads and configures runners automatically
- 🧹 **Disk pressure cleanup** — safely reclaim idle runner workspaces and CI caches

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
brew install --cask omniaura/tap/mac-runner
```

### Direct Download

Download the latest DMG from [Releases](https://github.com/omniaura/mac-runner/releases)

### Prerequisites

- macOS 13+ (macOS 15+ for user isolation, macOS 26+ for container isolation)
- [`gh` CLI](https://cli.github.com/) installed and authenticated (`gh auth login`)
- Apple Silicon Mac (for container isolation)

## Quick Start

### GUI

1. Launch Mac Runner from Applications or run `open /Applications/MacRunner.app` — it appears in the menu bar
2. Click "Add Runner"
3. Browse your repos (fetched via `gh`), pick one
4. Runner downloads, configures, registers, and starts automatically

### CLI

```bash
# Check GitHub auth
mac-runner auth

# Add a runner (downloads, configures, starts in background)
mac-runner add owner/repo --name my-runner --labels macos,mac-runner

# Add a runner with GUI access (for visual tests, Xcode UI tests, etc.)
mac-runner add owner/repo --enable-gui

# List runners
mac-runner list

# Start/stop
mac-runner start my-runner
mac-runner stop my-runner

# Remove (deregisters from GitHub and deletes the runner's workspace)
mac-runner remove my-runner

# Status summary
mac-runner status

# Preview or run cleanup (active runner data is always skipped)
mac-runner cleanup --dry-run
mac-runner cleanup

# Remove every runner and every file Mac Runner created
mac-runner uninstall --dry-run
mac-runner uninstall
```

Runners started via CLI persist in the background — they survive the terminal session. Stop and start them from any terminal or from the GUI.

### Disk Cleanup

GitHub Actions jobs can leave large workspaces and dependency caches behind. `mac-runner cleanup` removes the contents of stopped runners' `_work` directories plus known npm, SwiftPM, Homebrew, Go, Cargo, Gradle, and Xcode caches. If any runner is active, its workspace is skipped and shared caches are preserved.

In Settings, enable **Clean CI Data When Disk Space Is Low** and choose a minimum free-space target. Mac Runner checks at most once per hour and only cleans when available space falls below that target. Automatic cleanup is off by default.

Use `mac-runner cleanup --workspaces-only` to preserve all shared caches.

### Uninstalling

`mac-runner uninstall` tears down a Mac Runner installation completely. It stops running
runners, deregisters them from GitHub, and deletes every location Mac Runner writes to:

| Location | Contents |
| --- | --- |
| `~/.mac-runner` | Runner workspaces — the extracted runner release and its `_work` checkout, typically >1 GB each |
| `~/Library/Application Support/MacRunner` | `config.json`, PID files, container kernel |
| `~/Library/Preferences/{com.omniaura.mac-runner,mac-runner}.plist` | App and CLI preferences |
| `~/Library/HTTPStorages/*`, `~/Library/Caches/*` | Cached update checks |
| `~/Library/Application Support/CrashReporter`, `~/Library/Logs/DiagnosticReports` | Crash and diagnostic reports |

Deregistering first matters: deleting a runner's credentials without telling GitHub leaves
it listed as a permanently offline runner in the repository's Actions settings.

```bash
mac-runner uninstall --dry-run      # show exactly what would be deleted, and how much space
mac-runner uninstall                # prompts before deleting
mac-runner uninstall --yes          # skip the prompt
mac-runner uninstall --include-app  # also delete MacRunner.app and the mac-runner symlink
mac-runner uninstall --keep-runners # delete local files but leave GitHub registrations
```

Uninstall also removes **orphaned workspaces** — directories left on disk by earlier
versions that deleted a runner from `config.json` without deleting its files. If you have
been using Mac Runner for a while, `--dry-run` is worth running even if you have no runners
configured.

If you installed with Homebrew, remove the app itself with `brew uninstall --cask mac-runner`.
Use `brew uninstall --zap --cask mac-runner` to remove the app and all of its data in one step.

**Run `mac-runner uninstall` first if you have runners configured.** Homebrew only deletes
local files: it cannot deregister your runners from GitHub, and it cannot reach workspaces
owned by a dedicated service user, which live outside your home directory. Runners removed
without deregistering stay listed in the repository's Actions settings as permanently
offline.

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

## GUI Access

By default, runners operate in **headless mode** — they run without access to the GUI (display, windows, etc.). This is optimal for most CI jobs and prevents interference with your desktop.

**When to enable GUI access:**
- Visual testing (screenshot comparisons, E2E tests with browsers)
- Xcode UI tests
- iOS Simulator tests
- macOS app GUI automation

**How to enable:**
```bash
# CLI
mac-runner add owner/repo --enable-gui

# GUI
Add Runner → Enable GUI Access (toggle)
```

**Note:** GUI sessions are currently shared across runners. For full isolation (separate GUI session per runner), see [Issue #27](https://github.com/omniaura/mac-runner/issues/27).

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
