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
    SUDO=""
    if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

    # Use the image's Actions runner if it has one, else download it.
    RUNNER_HOME=""
    for dir in ${MR_RUNNER_CANDIDATES:-/home/runner /actions-runner /runner}; do
      if [ -x "$dir/run.sh" ]; then RUNNER_HOME="$dir"; break; fi
    done
    if [ -z "$RUNNER_HOME" ]; then
      RUNNER_HOME=/runner
      log "No Actions runner in this image; downloading $MR_RUNNER_URL"
      mkdir -p "$RUNNER_HOME"
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
          $SUDO apt-get update -qq
          $SUDO apt-get install -y -qq --no-install-recommends curl ca-certificates >/dev/null
          curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | $SUDO tee /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null
          echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
          packages="$packages gh"
        fi
        if [ -n "${packages// /}" ]; then
          log "Installing tools:$packages"
          $SUDO apt-get update -qq
          # shellcheck disable=SC2086
          $SUDO apt-get install -y -qq --no-install-recommends $packages >/dev/null || log "Some tools failed to install"
        fi
      else
        log "This image has no apt-get; skipping tool installation"
      fi
    fi

    # Keep job workspaces and diagnostics on the host.
    mkdir -p "$MR_WORK_DIR" "$MR_DIAG_DIR"
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
        ]
    }
}
