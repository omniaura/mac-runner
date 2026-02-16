cask "mac-runner" do
  version "1.6.1"
  sha256 "7740e29e9b0545eb02f2d77f4c28c006f35f0bbca37fc6d7cd23c4ec31823428"

  url "https://github.com/omniaura/mac-runner/releases/download/v#{version}/MacRunner-#{version}.zip"
  name "Mac Runner"
  desc "Menu bar app for managing GitHub Actions self-hosted runners"
  homepage "https://github.com/omniaura/mac-runner"

  depends_on macos: ">= :ventura"

  app "MacRunner.app"
  binary "#{appdir}/MacRunner.app/Contents/MacOS/MacRunner", target: "mac-runner"

  zap trash: [
    "~/Library/Application Support/MacRunner",
    "~/Library/Preferences/com.omniaura.mac-runner.plist",
  ]

  caveats <<~EOS
    Mac Runner is currently unsigned. On first launch, macOS will block it.
    To allow it, run:

      xattr -cr /Applications/MacRunner.app

    To get started:

    1. Install and authenticate the GitHub CLI: brew install gh && gh auth login
    2. Launch from Applications or run: open -a "Mac Runner"
    3. Click the runner icon in the menu bar and add a runner
    4. Or use the CLI: mac-runner add owner/repo --name my-runner

    For help: https://github.com/omniaura/mac-runner
  EOS
end
