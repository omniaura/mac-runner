cask "mac-runner" do
  version "1.18.0"
  sha256 "5ee9a9554e8f11b961c861f1cc8322e3a245b6a9e2d14aac8d083a9397f5ca7b"

  url "https://github.com/omniaura/mac-runner/releases/download/v#{version}/MacRunner-#{version}.zip"
  name "Mac Runner"
  desc "Menu bar app for managing GitHub Actions self-hosted runners"
  homepage "https://github.com/omniaura/mac-runner"

  depends_on macos: ">= :ventura"

  app "MacRunner.app"
  binary "#{appdir}/MacRunner.app/Contents/MacOS/MacRunner", target: "mac-runner"

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
  EOS
end
