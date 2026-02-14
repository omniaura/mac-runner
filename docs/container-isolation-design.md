# Container Isolation Design for Mac Runner

## Overview

This document details the design for implementing container isolation in Mac Runner using Apple's Containerization framework. This will enable Mac Runner to execute Linux-based GitHub Actions workflows in isolated, secure containers.

## System Requirements

- Mac with Apple silicon
- macOS 26.0+
- Xcode 26.0+
- Linux kernel 6.14.9+ with VIRTIO drivers

**Fallback Strategy**: On systems that don't meet these requirements, Mac Runner will continue using user isolation (already implemented in PR #7).

## Architecture Overview

### Current State (User Isolation)

```
┌─────────────────────────────────────┐
│  Mac Runner (Main Process)          │
│  ├─ Runner 1 (macOS, user: runner1) │
│  ├─ Runner 2 (macOS, user: runner2) │
│  └─ Runner 3 (macOS, user: runner3) │
└─────────────────────────────────────┘
```

### Target State (Hybrid Isolation)

```
┌────────────────────────────────────────────────────┐
│  Mac Runner (Main Process)                         │
│  ├─ Runner 1 (macOS, user: runner1)                │
│  ├─ Runner 2 (macOS, user: runner2)                │
│  ├─ Runner 3 (Linux, container via Virtualization) │
│  └─ Runner 4 (Linux, container via Virtualization) │
└────────────────────────────────────────────────────┘
```

## Apple Containerization API

### Key Components

1. **ContainerManager**: High-level API for container lifecycle
   - Manages image store, networking, and virtual machine manager
   - Creates containers from OCI image references

2. **LinuxContainer**: Represents a running container
   - Lifecycle methods: `create()`, `start()`, `wait()`, `stop()`
   - Configuration: CPU, memory, networking, mounts, process config

3. **ImageStore**: OCI image management and registry interaction

4. **VirtualMachineManager**: VM lifecycle for containers

### Basic Usage Pattern

```swift
// 1. Create container manager
let manager = try await ContainerManager(
    kernel: Kernel(path: kernelURL, platform: .linuxArm),
    initfsReference: "ghcr.io/apple/containerization/vminit:0.13.0",
    network: try ContainerManager.VmnetNetwork()
)

// 2. Create container from OCI image
let container = try await manager.create(
    "container-id",
    reference: "docker.io/library/ubuntu:22.04",
    rootfsSizeInBytes: 4.gib()
) { config in
    config.cpus = 2
    config.memoryInBytes = 2.gib()
    config.process.arguments = ["/bin/bash", "-c", "runner script"]
    config.process.workingDirectory = "/runner"
}

// 3. Run container
try await container.create()
try await container.start()
let exitCode = try await container.wait()
try await container.stop()

// 4. Cleanup
try manager.delete("container-id")
```

## Implementation Plan

### Phase 1: Infrastructure Setup ✅ (Current Task)

**Goal**: Add framework dependencies and create basic container services.

**Tasks**:
- [x] Research Apple Containerization API (DONE)
- [x] Study example code and usage patterns (DONE)
- [ ] Update Package.swift with Containerization dependency
- [ ] Add macOS version detection utility
- [ ] Create `ContainerIsolationService.swift` stub
- [ ] Add system requirement validation

**Acceptance Criteria**:
- Mac Runner builds successfully with Containerization framework
- System can detect if container isolation is available
- Basic service structure is in place

### Phase 2: Runner Model Extension

**Goal**: Extend Runner model to support different isolation types.

**Tasks**:
- [ ] Add `IsolationType` enum to Runner model
  ```swift
  enum IsolationType: String, Codable {
      case user       // Existing user isolation
      case container  // New container isolation
      case none       // No isolation (for testing)
  }
  ```
- [ ] Add `isolationType` property to `Runner` struct
- [ ] Update `RunnerConfiguration` to include isolation preferences
- [ ] Modify persistence layer to save/load isolation type
- [ ] Add migration for existing runners (default to `.user`)

**Acceptance Criteria**:
- Runner model can represent isolation type
- Existing runners continue working (backward compatible)
- Isolation type persists across app restarts

### Phase 3: Container Lifecycle Service

**Goal**: Implement complete container lifecycle management.

**Tasks**:
- [ ] Implement `ContainerIsolationService`
  - Container creation from GitHub runner image
  - Network configuration (bridge networking)
  - Volume mounts for runner workspace
  - Process spawning and monitoring
  - Cleanup and teardown
- [ ] Create default runner image configuration
  - Base image: Ubuntu 22.04 or similar
  - Pre-installed: Node.js, Git, GitHub Actions dependencies
  - Runner binary installation at runtime
- [ ] Implement container resource limits (CPU, memory)
- [ ] Add container logging and diagnostics

**Technical Details**:

```swift
class ContainerIsolationService {
    private var containerManager: ContainerManager?
    private let kernelPath: URL
    private let imageStore: URL

    func initialize() async throws {
        // Initialize container manager with kernel and network
        self.containerManager = try await ContainerManager(
            kernel: try await loadKernel(),
            initfsReference: "ghcr.io/apple/containerization/vminit:0.13.0",
            network: try ContainerManager.VmnetNetwork()
        )
    }

    func createRunnerContainer(
        id: String,
        config: RunnerConfiguration
    ) async throws -> LinuxContainer {
        guard let manager = containerManager else {
            throw ContainerError.notInitialized
        }

        return try await manager.create(
            id,
            reference: config.containerImage ?? "ghcr.io/actions/runner:latest",
            rootfsSizeInBytes: 4.gib()
        ) { containerConfig in
            containerConfig.cpus = config.cpuCount ?? 2
            containerConfig.memoryInBytes = config.memoryInBytes ?? 2.gib()

            // Mount runner workspace
            containerConfig.mounts.append(
                Mount(
                    source: config.workspaceURL.path,
                    destination: "/runner/_work",
                    type: "virtiofs"
                )
            )

            // Set runner process
            containerConfig.process.arguments = [
                "/runner/run.sh",
                "--url", config.repositoryURL,
                "--token", config.registrationToken
            ]
            containerConfig.process.workingDirectory = "/runner"
        }
    }

    func startContainer(_ container: LinuxContainer) async throws {
        try await container.create()
        try await container.start()
    }

    func stopContainer(_ container: LinuxContainer) async throws {
        try await container.stop()
    }
}
```

**Acceptance Criteria**:
- Can create Linux containers from OCI images
- Containers have network access
- Runner workspace is accessible inside container
- Containers clean up properly after stopping

### Phase 4: Runner Manager Integration

**Goal**: Integrate container isolation into existing RunnerManager.

**Tasks**:
- [ ] Extend `RunnerManager` to choose isolation strategy
  ```swift
  func installRunner(config: RunnerConfiguration) async throws {
      switch config.isolationType {
      case .user:
          try await installUserIsolatedRunner(config)
      case .container:
          try await installContainerIsolatedRunner(config)
      case .none:
          try await installStandardRunner(config)
      }
  }
  ```
- [ ] Implement automatic isolation detection
  - Parse runner labels for platform indicators
  - Default to user isolation for backward compatibility
  - Allow manual override via configuration
- [ ] Update runner installation flow
- [ ] Update runner start/stop logic
- [ ] Add container status monitoring

**Acceptance Criteria**:
- RunnerManager correctly routes to appropriate isolation method
- User isolation runners continue working unchanged
- Container isolation runners start and execute workflows
- Status updates work for both isolation types

### Phase 5: CLI & GUI Updates

**Goal**: Expose container isolation in user interfaces.

**Tasks**:
- [ ] Add `--isolation` flag to CLI
  ```bash
  mac-runner install --url <repo> --isolation container
  mac-runner install --url <repo> --isolation user
  mac-runner install --url <repo> --isolation auto
  ```
- [ ] Update GUI to show isolation type per runner
  - Visual indicator (icon/badge)
  - Isolation type in runner details
- [ ] Add isolation type selector in add runner dialog
- [ ] Display system compatibility warnings
  - "Container isolation requires macOS 26+"
  - "Falling back to user isolation"

**Acceptance Criteria**:
- Users can specify isolation type when adding runners
- GUI clearly shows which isolation each runner uses
- Helpful error messages for unsupported configurations

### Phase 6: Testing & Documentation

**Goal**: Validate implementation and document usage.

**Tasks**:
- [ ] Unit tests
  - ContainerIsolationService tests
  - Runner model isolation type tests
  - Isolation detection logic tests
- [ ] Integration tests
  - End-to-end container runner workflow
  - Mixed user + container runners
  - Fallback scenarios
- [ ] Manual testing
  - Run real GitHub Actions workflows
  - Test network isolation
  - Verify no visible side effects
  - Performance benchmarks (startup time)
- [ ] Documentation
  - Update README with container isolation section
  - Add system requirements
  - Document CLI flags and GUI features
  - Create troubleshooting guide
  - Add architecture diagrams

**Acceptance Criteria**:
- All tests passing
- Documentation complete and accurate
- Troubleshooting guide addresses common issues
- Performance meets < 2s startup requirement

## Design Decisions

### 1. Isolation Type Selection

**Decision**: Automatic detection with manual override

**Rationale**:
- **Automatic**: Analyze runner labels/configuration
  - If runner has `linux` label → suggest container isolation
  - If runner has `macos` label → use user isolation
  - Default to user isolation for backward compatibility
- **Manual**: Users can explicitly choose via CLI/GUI
  - Provides control for advanced users
  - Allows testing and experimentation

### 2. Container Base Image

**Decision**: Support multiple base images with sensible default

**Options Considered**:
1. ✅ **Custom runner image** (CHOSEN)
   - Use pre-built GitHub Actions runner image
   - Reference: `ghcr.io/actions/runner:latest`
   - Pros: Batteries-included, maintained by GitHub
   - Cons: Larger image size

2. Ubuntu base + runtime installation
   - Pull `ubuntu:22.04`, install runner at container start
   - Pros: Smaller base image
   - Cons: Slower startup, more complex

3. User-provided images
   - Allow custom OCI image references
   - Pros: Maximum flexibility
   - Cons: User must ensure runner dependencies

**Implementation**: Start with option 1, add option 3 in future release.

### 3. Resource Allocation

**Decision**: Configurable with sensible defaults

**Default Resources**:
- CPUs: 2 cores
- Memory: 2 GiB
- Disk: 4 GiB root filesystem
- Network: vmnet shared mode

**Configuration**:
```swift
struct ContainerResourceConfig {
    var cpuCount: Int = 2
    var memoryInBytes: UInt64 = 2.gib()
    var diskSizeInBytes: UInt64 = 4.gib()
    var enableNestedVirtualization: Bool = false
}
```

### 4. Backward Compatibility

**Decision**: Strict backward compatibility, graceful degradation

**Strategy**:
- Existing user-isolated runners continue working unchanged
- New container features require explicit opt-in
- On unsupported systems (macOS < 26), fall back to user isolation
- Show clear warnings when container isolation unavailable

### 5. Kernel & Init System

**Decision**: Bundle optimized kernel, fetch vminit from registry

**Kernel**:
- Use Apple's provided kernel configuration
- Bundle kernel binary with Mac Runner
- Store in Resources or download on first use

**Init System (vminit)**:
- Fetch from `ghcr.io/apple/containerization/vminit:0.13.0`
- Cache locally after first download
- Required for container process management

## File Structure

```
Sources/
├── Models/
│   ├── Runner.swift                    # Add IsolationType enum
│   └── RunnerConfiguration.swift       # Add isolation config
├── Services/
│   ├── ContainerIsolationService.swift # NEW: Container lifecycle
│   ├── UserIsolationService.swift      # Extract user isolation logic
│   ├── RunnerManager.swift             # Update to route isolation
│   └── SystemRequirements.swift        # NEW: Version detection
├── Views/
│   ├── MenuBarView.swift               # Update to show isolation type
│   └── AddRunnerView.swift             # Add isolation selector
└── Resources/
    └── vmlinux                          # Bundled Linux kernel (if bundled)
```

## Testing Strategy

### Unit Tests
- [ ] IsolationType enum coding/decoding
- [ ] SystemRequirements.supportsContainerIsolation()
- [ ] ContainerIsolationService initialization
- [ ] RunnerManager isolation routing logic

### Integration Tests
- [ ] Create and start containerized runner
- [ ] Execute simple workflow in container
- [ ] Container cleanup after runner stops
- [ ] Mixed user + container runners

### Manual Testing Checklist
- [ ] Add container-isolated runner via GUI
- [ ] Add container-isolated runner via CLI
- [ ] Run GitHub Actions workflow (Linux)
- [ ] Verify no DMG popups or visible side effects
- [ ] Verify network isolation (no access to host)
- [ ] Test on macOS 26+ (container works)
- [ ] Test on macOS < 26 (falls back to user isolation)
- [ ] Measure container startup time (< 2s target)

## Success Metrics

- ✅ Linux runners execute in isolated containers
- ✅ macOS runners continue using user isolation
- ✅ No visible side effects from containerized runners
- ✅ Container startup time < 2 seconds
- ✅ Backward compatible with existing installations
- ✅ Clear documentation and troubleshooting guides

## Open Questions

1. **Kernel distribution**: Bundle with app or download on-demand?
   - **Proposal**: Download on first use, cache locally
   - Reduces app bundle size
   - Automatic updates to newer kernel versions

2. **Image caching**: How to manage OCI image cache size?
   - **Proposal**: Leverage ContainerManager's ImageStore
   - Implement cache cleanup (LRU eviction)
   - Add GUI/CLI for cache management

3. **Multi-architecture**: Support linux/amd64 via Rosetta?
   - **Proposal**: Yes, enable by default
   - ContainerizationAPI supports Rosetta 2 translation
   - May have performance implications

4. **Container lifecycle**: Should containers persist between workflow runs?
   - **Proposal**: Ephemeral containers (destroy after each run)
   - Matches GitHub's hosted runner behavior
   - Simpler implementation, cleaner state

## References

- [Apple Containerization Framework](https://github.com/apple/containerization)
- [Apple Containerization Docs](https://apple.github.io/containerization/documentation/)
- [Technical Overview](https://github.com/apple/container/blob/main/docs/technical-overview.md)
- [PR #7 (User Isolation)](https://github.com/omniaura/mac-runner/pull/7)
- [Issue #9 (Hybrid Isolation)](https://github.com/omniaura/mac-runner/issues/9)
