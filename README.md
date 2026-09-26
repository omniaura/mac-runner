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
- 🤖 **Fully automated setup**: downloads and configures runners automatically, and provisions `gh` plus the repo's toolchains (Node, Python, Go, Ruby, Rust) on the host or in containers
- 🧹 **Disk pressure cleanup**: safely reclaim idle runner workspaces and CI caches
- 🔋 **Auto-pause**: pause runners on low battery or during quiet hours (per-runner schedules), finishing the current job first and resuming automatically
- 📈 **Resource monitoring**: per-runner CPU, memory, and workspace size, with optional alerts (`mac-runner status --resources`)
- 📜 **Log viewer**: live-tail, filter, and export runner output and diagnostics (`mac-runner logs <name> --follow`), with log rotation
- 🪟 **Dashboard window**: every runner's status, current job, recent jobs, resources, and logs in one window
- 🔔 **Job notifications**: native notifications when jobs start and finish (caught from each runner's own log, so even jobs of a few seconds show up), and an animated menu bar icon while any runner is executing
- 📦 **Custom container images**: run Linux runners on your own OCI images (linux/arm64 with `bash`; see [Container Isolation](#3-container-isolation-macos-26-apple-silicon) for requirements), each with its own virtual display when GUI access is on
- 🗂️ **Declarative config**: describe runners in `.mac-runner.yml` and `mac-runner apply` them (`mac-runner export` to start)

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

## Declarative Configuration

Describe your runners in a file and let `mac-runner apply` create, update, and remove them to match. This makes a setup easy to reproduce on another Mac or to keep in version control.

```bash
# Start from what you have now
mac-runner export -o .mac-runner.yml

# Preview, then apply
mac-runner apply --dry-run
mac-runner apply
```

`apply` reads `-f <path>`, or `./.mac-runner.yml`, or `~/.mac-runner/config.yml`, in that order. It prints its plan first and asks before removing or re-registering runners (`--yes` skips the prompt). `--no-prune` keeps runners that aren't in the file. Running it again when nothing has changed does nothing.

```yaml
version: 1

# Optional global settings
settings:
  isolation: user                  # none | user | container
  quiet-hours: { start: "22:00", end: "06:00" }   # or: never
  pause-on-battery: true
  battery-threshold: 20            # percent, 5-95

runners:
  - name: mac-runner-ci            # letters, digits, . _ -
    repo: omniaura/mac-runner      # or `org: omniaura` for an organization runner
    labels: [macos, swift]         # default: [macos, mac-runner]
    count: 2                       # creates mac-runner-ci-1 and mac-runner-ci-2

  - name: linux-builder
    org: omniaura
    isolation: container           # none | user | container | global (default: global)
    enable-gui: false              # default: false (headless)
    open-files: 65536              # default: the global limit
    quiet-hours: never             # never | { start, end } (default: global schedule)
```

Runners are matched by name. What happens to an existing runner depends on what changed:

| Change | What `apply` does |
|---|---|
| New name | Registers and starts the runner |
| `repo`/`org`, `labels`, or `isolation` | Unregisters and registers the runner again |
| `enable-gui` or `open-files` | Updates it, restarting it if it's running |
| `quiet-hours` | Updates it in place |
| Name no longer in the file | Unregisters it and deletes its workspace (unless `--no-prune`) |

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
- Runs each runner as a **Linux** (arm64) runner inside its own lightweight VM, using Apple's [Containerization framework](https://github.com/apple/containerization)
- Best for Linux-based workflows and cross-platform testing
- **Requirements:** macOS 26+, Apple Silicon, and a Linux kernel (see below)
- **How to enable:**
  ```bash
  # CLI (default image: GitHub's ghcr.io/actions/actions-runner:latest)
  mac-runner add owner/repo --isolation container

  # With your own image
  mac-runner add owner/repo --isolation container --image ghcr.io/myorg/ci-image:latest

  # GUI
  Add Runner → Isolation Mode → Container (optionally set Container Image)
  ```

**Kernel.** Mac Runner looks for a Linux kernel at `MacRunner.app/Contents/Resources/vmlinux` or `~/Library/Application Support/MacRunner/vmlinux`. The [Kata Containers](https://github.com/kata-containers/kata-containers/releases) kernel works:
```bash
curl -fLO https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz
tar -xJf kata-static-3.17.0-arm64.tar.xz ./opt/kata/share/kata-containers/vmlinux.container
cp -L opt/kata/share/kata-containers/vmlinux.container ~/Library/Application\ Support/MacRunner/vmlinux
```

**Images.** Images are pulled from any public OCI registry (GHCR, Docker Hub, …) the first time a runner uses them and are cached locally after that. An image needs:
- linux/arm64 and `bash`
- Either the GitHub Actions runner already installed at `/home/runner`, `/actions-runner`, or `/runner` (as in `ghcr.io/actions/actions-runner`), or `curl` and `tar` so Mac Runner can download it at start
- `apt-get` (Debian/Ubuntu) if you want automatic tool installation. Other images still work; tools just aren't installed for you.
- For GUI access: `Xvfb` preinstalled, or `apt-get` with a default user that is root or has passwordless `sudo` so Mac Runner can install it. Otherwise the runner doesn't start, rather than running GUI jobs without a display.

**Tools.** When a container runner is created, Mac Runner picks the tools its jobs are likely to need: the GitHub CLI, toolchains detected from the repository (Node, Python, Go, Ruby, Rust), and any **Extra CI Tools** from Settings (installed as apt packages). They're installed with `apt-get` each time the runner's container starts, never per job.

**Lifetime.** A container runner's VM lives inside the process that started it. Start container runners from the menu bar app to keep them running in the background. `mac-runner add`/`start` for a container runner stays in the foreground and streams its output until you press Ctrl-C.

Container runners register with the name and labels you give them (default labels: `linux, mac-runner`). Their `runner.log` and `_diag` logs sit in the runner's directory like other modes (`mac-runner logs <name>`).

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

### Separate displays per runner

- **Container runners** with GUI access each get their **own virtual display**: Xvfb runs inside the runner's VM (1920×1080×24) and `DISPLAY` is set for its jobs, so windows, focus, and screenshots from one runner never touch another's. Linux GUI tests (headed browsers, Electron, X11 apps) run side by side without interfering. Headless container runners get `CI=true HEADLESS=true` like other modes.
- **macOS runners** (no isolation or a dedicated user) with GUI access share the logged-in user's desktop. macOS only gives a user a separate GUI session when that user actually logs in at the login window, and the dedicated `_macrunner` user has no password by design, so Mac Runner can't create one. For parallel macOS UI tests, either keep one GUI-enabled runner per Mac (target it with a label) or run Mac Runner inside separate macOS VMs, each with its own GUI-enabled runner.

## Roadmap

Planned work and ideas are tracked as [open enhancement issues](https://github.com/omniaura/mac-runner/issues?q=is%3Aopen+label%3Aenhancement). Their `priority:high`, `priority:medium`, and `priority:low` labels show priority (for example, [high-priority items](https://github.com/omniaura/mac-runner/issues?q=is%3Aopen+label%3Aenhancement+label%3Apriority%3Ahigh)). Open issues with a linked pull request are in progress. Suggestions are welcome: [open an issue](https://github.com/omniaura/mac-runner/issues/new).

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
