cask "mac-runner" do
  version "1.19.0"
  sha256 "b720a8543ab2540f9e96095f746aab5567d44ff17beb726db2e46519a75c310a"

  url "https://github.com/omniaura/mac-runner/releases/download/v#{version}/MacRunner-#{version}.zip"
  name "Mac Runner"
  desc "Menu bar app for managing GitHub Actions self-hosted runners"
  homepage "https://github.com/omniaura/mac-runner"

  depends_on macos: ">= :ventura"

  app "MacRunner.app"
  binary "#{appdir}/MacRunner.app/Contents/MacOS/MacRunner", target: "mac-runner"

  # `zap` is a blunt, whole-directory removal of the invoking user's files, which is
  # what `brew zap` is for. `mac-runner uninstall` is the surgical path: it deregisters
  # runners from GitHub, reaches service-user workspaces under /Users/<service-user>,
  # and preserves anything inside ~/.mac-runner it does not recognise as its own.
  zap trash: [
    # Runner workspaces live outside Application Support because the GitHub runner
    # scripts break on paths containing spaces. This is by far the largest artifact:
    # each configured runner holds an extracted runner release plus its _work checkout.
    "~/.mac-runner",
    "~/Library/Application Support/MacRunner",
    "~/Library/Application Support/CrashReporter/MacRunner_*.plist",
    "~/Library/Application Support/CrashReporter/mac-runner_*.plist",
    "~/Library/Logs/DiagnosticReports/MacRunner-*.ips",
    "~/Library/Logs/DiagnosticReports/mac-runner-*.ips",
    "~/Library/Caches/com.omniaura.mac-runner",
    "~/Library/HTTPStorages/com.omniaura.mac-runner",
    "~/Library/HTTPStorages/com.omniaura.mac-runner.binarycookies",
    "~/Library/HTTPStorages/mac-runner",
    "~/Library/HTTPStorages/MacRunner",
    "~/Library/Preferences/com.omniaura.mac-runner.plist",
    "~/Library/Preferences/mac-runner.plist",
    "~/Library/Saved Application State/com.omniaura.mac-runner.savedState",
  ]

  caveats <<~EOS
    To get started:

    1. Install and authenticate the GitHub CLI: brew install gh && gh auth login
    2. Launch from Applications or run: open /Applications/MacRunner.app
    3. Click the runner icon in the menu bar and add a runner
    4. Or use the CLI: mac-runner add owner/repo --name my-runner

    For help: https://github.com/omniaura/mac-runner

    To uninstall, run this first:

        mac-runner uninstall

    It deregisters your runners from GitHub - otherwise they linger in the
    repository's Actions settings as permanently offline runners - and removes
    workspaces owned by a dedicated service user, which live outside your home
    directory and are not reachable by `brew zap`.
  EOS
end
