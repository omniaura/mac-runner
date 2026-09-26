import Foundation

/// The script that boots a GitHub Actions runner inside a Linux container.
///
/// Inputs arrive as `MR_*` environment variables rather than being spliced
/// into the script, so names, labels, and tokens need no shell quoting.
enum ContainerRunnerScript {
    /// Where the host's `_work` and `_diag` directories are mounted.
    static let workMount = "/mac-runner/_work"
    static let diagnosticsMount = "/mac-runner/_diag"

    static let script = #"""
    set -euo pipefail
    log() { echo "[mac-runner] $*"; }
    # GitHub's runner image copies its diagnostics to stdout; they're in _diag already.
    unset ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT
    if [ -n "${MR_SUDO+set}" ]; then SUDO="$MR_SUDO"
    elif [ "$(id -u)" -ne 0 ]; then SUDO="sudo"
    else SUDO=""; fi
    # Make a directory owned by this user, using sudo only if needed.
    ensure_dir() {
      mkdir -p "$1" 2>/dev/null || $SUDO mkdir -p "$1"
      [ -w "$1" ] || $SUDO chown "$(id -u):$(id -g)" "$1"
    }
    # Don't register a runner that's missing tools its jobs were promised.
    fail_tools() {
      log "ERROR: tool installation failed ($1). Not starting the runner so jobs don't run without these tools."
      log "Fix the package list (Settings → Extra CI Tools) or use an image that has them, then start the runner again."
      exit 1
    }

    # Use the image's Actions runner if it has one, else download it.
    RUNNER_HOME=""
    for dir in ${MR_RUNNER_CANDIDATES:-/home/runner /actions-runner /runner}; do
      if [ -x "$dir/run.sh" ]; then RUNNER_HOME="$dir"; break; fi
    done
    if [ -z "$RUNNER_HOME" ]; then
      RUNNER_HOME=/runner
      log "No Actions runner in this image; downloading $MR_RUNNER_URL"
      ensure_dir "$RUNNER_HOME"
      cd "$RUNNER_HOME"
      curl -fsSL -o runner.tar.gz "$MR_RUNNER_URL"
      tar -xzf runner.tar.gz
      rm runner.tar.gz
      $SUDO ./bin/installdependencies.sh >/dev/null || log "installdependencies.sh failed; continuing"
    fi

    # Tools picked when the runner was created.
    if [ -n "${MR_APT_PACKAGES:-}" ] || [ "${MR_INSTALL_GH:-0}" = 1 ]; then
      if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        packages="${MR_APT_PACKAGES:-}"
        if [ "${MR_INSTALL_GH:-0}" = 1 ] && ! command -v gh >/dev/null 2>&1; then
          log "Adding the GitHub CLI apt repository"
          if ! { $SUDO apt-get update -qq \
                 && $SUDO apt-get install -y -qq --no-install-recommends curl ca-certificates >/dev/null \
                 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                    | $SUDO tee /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null \
                 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
                    | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null; }; then
            fail_tools "could not add the GitHub CLI apt repository"
          fi
          packages="$packages gh"
        fi
        packages="$(echo $packages)"  # normalize spacing
        if [ -n "$packages" ]; then
          log "Installing tools: $packages"
          $SUDO apt-get update -qq || log "apt-get update failed; trying the install anyway"
          # shellcheck disable=SC2086
          $SUDO apt-get install -y -qq --no-install-recommends $packages >/dev/null \
            || fail_tools "could not install: $packages"
        fi
      else
        log "This image has no apt-get; skipping tool installation"
      fi
    fi

    # GUI runners get their own virtual display; headless ones are marked as such.
    if [ "${MR_ENABLE_GUI:-0}" = 1 ]; then
      if ! command -v Xvfb >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        log "Installing Xvfb for this runner's virtual display"
        $SUDO apt-get update -qq || log "apt-get update failed; trying the install anyway"
        DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq --no-install-recommends xvfb xauth x11-utils >/dev/null \
          || log "Could not install Xvfb"
      fi
      if ! command -v Xvfb >/dev/null 2>&1; then
        log "ERROR: GUI access needs Xvfb, and this image has neither Xvfb nor apt-get. Use an image with Xvfb, or turn off GUI access."
        exit 1
      fi
      display_number="${MR_DISPLAY#:}"
      x11_socket="${MR_X11_DIR:-/tmp/.X11-unix}/X$display_number"
      # A leftover socket or lock would look like a running display.
      rm -f "$x11_socket" "/tmp/.X$display_number-lock" 2>/dev/null \
        || $SUDO rm -f "$x11_socket" "/tmp/.X$display_number-lock" 2>/dev/null || true
      Xvfb "$MR_DISPLAY" -screen 0 "${MR_DISPLAY_SIZE:-1920x1080x24}" -nolisten tcp >/dev/null 2>&1 &
      xvfb_pid=$!
      # Ready means: Xvfb is still running, its socket exists, and (when
      # xdpyinfo is available) a client can actually connect.
      display_ready=""
      for _ in $(seq 1 100); do
        kill -0 "$xvfb_pid" 2>/dev/null || break
        if [ -S "$x11_socket" ]; then
          if ! command -v xdpyinfo >/dev/null 2>&1 || DISPLAY="$MR_DISPLAY" xdpyinfo >/dev/null 2>&1; then
            display_ready=1
            break
          fi
        fi
        sleep 0.1
      done
      sleep 0.3
      kill -0 "$xvfb_pid" 2>/dev/null || display_ready=""
      if [ -z "$display_ready" ]; then
        log "ERROR: the virtual display $MR_DISPLAY did not start. Not starting the runner so GUI jobs don't run without a display."
        exit 1
      fi
      export DISPLAY="$MR_DISPLAY"
      log "Virtual display $DISPLAY (${MR_DISPLAY_SIZE:-1920x1080x24})"
    else
      export CI=true HEADLESS=true
    fi

    # Keep job workspaces and diagnostics on the host, writable by this user.
    ensure_dir "$MR_WORK_DIR"
    ensure_dir "$MR_DIAG_DIR"
    if [ ! -L "$RUNNER_HOME/_diag" ]; then
      rm -rf "$RUNNER_HOME/_diag"
      ln -s "$MR_DIAG_DIR" "$RUNNER_HOME/_diag"
    fi

    cd "$RUNNER_HOME"
    ./config.sh --unattended --replace \
      --url "$MR_URL" --token "$MR_TOKEN" \
      --name "$MR_NAME" --labels "$MR_LABELS" --work "$MR_WORK_DIR"
    unset MR_TOKEN
    ulimit -n "$MR_OPEN_FILES" 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
    exec ./run.sh
    """#

    /// X display for GUI-enabled container runners. Each runner has its own VM,
    /// so every runner gets a separate display even though the name is shared.
    static let displayName = ":99"

    /// DNS-safe hostname for a runner's container.
    static func hostname(for runnerName: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let mapped = String(runnerName.lowercased().map { allowed.contains($0) ? $0 : "-" })
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "mac-runner" : String(trimmed.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// apt packages for tool names from `ToolProvisioningService.plan`, and
    /// whether the GitHub CLI (from its own apt repository) is wanted.
    static func aptPackages(for tools: [String]) -> (packages: [String], installGitHubCLI: Bool) {
        var packages: [String] = []
        var installGitHubCLI = false
        for tool in tools {
            switch tool {
            case "gh": installGitHubCLI = true
            case "node": packages += ["nodejs", "npm"]
            case "python": packages += ["python3", "python3-pip", "python3-venv"]
            case "go": packages += ["golang-go"]
            case "ruby": packages += ["ruby-full"]
            case "rust": packages += ["cargo", "rustc"]
            default: packages.append(tool)
            }
        }
        var seen = Set<String>()
        return (packages.filter { seen.insert($0).inserted }, installGitHubCLI)
    }

    static func environment(for config: ContainerRunnerConfiguration) -> [String] {
        let apt = aptPackages(for: config.tools)
        return [
            "RUNNER_ALLOW_RUNASROOT=1",
            "MR_URL=\(config.repositoryURL)",
            "MR_TOKEN=\(config.registrationToken)",
            "MR_NAME=\(config.runnerName)",
            "MR_LABELS=\(config.labels.joined(separator: ","))",
            "MR_RUNNER_URL=\(config.runnerDownloadURL)",
            "MR_OPEN_FILES=\(config.openFileLimit)",
            "MR_WORK_DIR=\(workMount)",
            "MR_DIAG_DIR=\(diagnosticsMount)",
            "MR_APT_PACKAGES=\(apt.packages.joined(separator: " "))",
            "MR_INSTALL_GH=\(apt.installGitHubCLI ? 1 : 0)",
            "MR_ENABLE_GUI=\(config.enableGUI ? 1 : 0)",
            "MR_DISPLAY=\(displayName)",
        ]
    }
}
