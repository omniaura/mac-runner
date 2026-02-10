# Mac Runner Architecture

## Overview

Native macOS menu bar app for managing multiple GitHub Actions self-hosted runners.

## Core Components

### 1. Menu Bar Interface

**Technology:** SwiftUI + AppKit

```
┌─────────────────────┐
│ 🏃 Mac Runner       │
├─────────────────────┤
│ ● Repo A (active)   │
│ ● Repo B (active)   │
│ ○ Repo C (paused)   │
├─────────────────────┤
│ ⏸️  Pause All       │
│ ▶️  Resume All      │
│ ⚙️  Settings        │
│ ❌ Quit             │
└─────────────────────┘
```

**Features:**
- Real-time runner status
- Quick pause/resume controls
- Minimal, clean design
- Native macOS look & feel

### 2. Runner Manager

**Responsibilities:**
- Start/stop runner processes
- Monitor runner health
- Handle graceful shutdowns
- Manage multiple instances

**Implementation:**

```swift
class RunnerManager: ObservableObject {
    @Published var runners: [Runner] = []

    func startRunner(_ config: RunnerConfig) async throws
    func stopRunner(_ id: UUID) async throws
    func pauseAll() async throws
    func resumeAll() async throws
    func getStatus(_ id: UUID) -> RunnerStatus
}
```

### 3. GitHub Runner Process

**How it works:**

1. Download GitHub Actions runner binary
2. Configure with PAT token
3. Start runner process: `./run.sh`
4. Monitor process health
5. Handle graceful shutdown: `./run.sh stop`

**Per-runner directory:**
```
~/Library/Application Support/MacRunner/runners/
├── runner-1/
│   ├── run.sh
│   ├── config.sh
│   └── .credentials
├── runner-2/
│   ├── run.sh
│   ├── config.sh
│   └── .credentials
```

### 4. Configuration Storage

**Format:** JSON

```json
{
  "runners": [
    {
      "id": "uuid",
      "name": "Repo A Runner",
      "repo": "owner/repo",
      "token": "encrypted",
      "enabled": true,
      "labels": ["macos", "xcode"]
    }
  ],
  "settings": {
    "startOnLogin": true,
    "pauseOnBattery": false,
    "quietHours": {
      "enabled": false,
      "start": "22:00",
      "end": "08:00"
    }
  }
}
```

**Storage:** `~/Library/Application Support/MacRunner/config.json`

### 5. GitHub API Integration

**Endpoints used:**

- `POST /repos/{owner}/{repo}/actions/runners/registration-token`
  - Get runner registration token

- `GET /repos/{owner}/{repo}/actions/runners`
  - List runners for repo
  - Monitor runner status

- `DELETE /repos/{owner}/{repo}/actions/runners/{runner_id}`
  - Remove runner

**Authentication:** Personal Access Token (PAT) with `repo` scope

### 6. Process Management

**LaunchAgent approach:**

Each runner runs as a managed process:

```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "\(runnerDir)/run.sh")
process.currentDirectoryURL = URL(fileURLWithPath: runnerDir)

// Monitor output
let pipe = Pipe()
process.standardOutput = pipe
process.standardError = pipe

// Handle termination
process.terminationHandler = { process in
    // Update status, restart if needed
}

try process.run()
```

## User Flows

### First Launch

1. User opens Mac Runner
2. Welcome screen: "Add your first runner"
3. User enters:
   - GitHub PAT token
   - Repo URL
   - Runner name (optional)
4. App downloads runner binary
5. Configures and starts runner
6. Success! Menu bar shows active runner

### Adding Another Runner

1. Click menu bar icon → Settings
2. Click "Add Runner"
3. Enter repo details
4. Runner starts automatically
5. Both runners shown in menu

### Pausing for Intensive Work

1. Click menu bar icon
2. Click "Pause All"
3. All runners gracefully shutdown
4. Menu bar shows "Paused (3)"
5. When done, click "Resume All"
6. All runners restart and reconnect

### Removing a Runner

1. Settings → Runner list
2. Select runner
3. Click "Remove"
4. Confirms: "This will unregister the runner from GitHub"
5. Runner stopped and removed

## Technical Decisions

### Why Swift/SwiftUI?

- Native macOS performance
- Small app size
- Access to AppKit for menu bar
- Modern Swift Concurrency for async operations
- No Electron overhead

### Why Menu Bar App?

- Always accessible
- Minimal UI footprint
- Perfect for background services
- Native macOS pattern

### Why Multiple Runners?

Official GitHub runner has limitations:
- One runner per machine
- No easy multi-repo support
- Manual process management

Mac Runner solves this with isolated runner instances.

### Runner Binary Management

Instead of embedding the runner binary:
- Download on demand from GitHub releases
- Cache locally
- Update check on launch
- Keeps app size small

## Security

### Token Storage

PAT tokens encrypted using macOS Keychain:

```swift
let keychain = Keychain(service: "com.omniaura.mac-runner")
try keychain.set(token, key: "github-pat-\(runnerId)")
```

### Sandboxing

App runs with minimal permissions:
- Network access (GitHub API)
- File access (runner directory)
- No unnecessary entitlements

### Best Practices

- Tokens never logged
- Secure token input (password field)
- Option to use environment variables
- Clear warning about PAT scope requirements

## Future Enhancements

### Phase 1 (MVP)
- [x] Menu bar interface
- [x] Add/remove runners
- [x] Pause/resume all
- [x] Basic status monitoring

### Phase 2
- [ ] Per-runner enable/disable
- [ ] Resource usage graphs
- [ ] Job history
- [ ] Notifications

### Phase 3
- [ ] Auto-pause rules (battery, time, CPU)
- [ ] Runner groups
- [ ] Webhook support
- [ ] Multi-machine coordination

### Phase 4
- [ ] CI/CD templates
- [ ] Runner fleet analytics
- [ ] Cost tracking
- [ ] Enterprise features

## Development Setup

### Requirements

- macOS 13+ (Ventura or later)
- Xcode 15+
- Swift 6
- GitHub PAT with `repo` scope

### Building

```bash
# Open in Xcode
open MacRunner.xcodeproj

# Or build from CLI
xcodebuild -project MacRunner.xcodeproj \
  -scheme MacRunner \
  -configuration Release \
  build
```

### Testing

```bash
# Run tests
xcodebuild test -project MacRunner.xcodeproj \
  -scheme MacRunner \
  -destination 'platform=macOS'
```

## Deployment

### Distribution

1. **Direct Download** - GitHub Releases
2. **Homebrew Cask** - `brew install --cask mac-runner`
3. **Future:** Mac App Store (requires notarization)

### Updates

Built-in update checker using Sparkle framework or manual check against GitHub releases API.

## Related Projects

- [actions/runner](https://github.com/actions/runner) - Official GitHub Actions runner
- [FastlaneCI](https://github.com/fastlane/ci) - Similar CI runner management
- [Bartender](https://www.macbartender.com/) - Menu bar organization (inspiration)

## License

MIT
