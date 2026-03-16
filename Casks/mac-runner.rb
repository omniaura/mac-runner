cask "mac-runner" do
  version "1.10.1"
  sha256 "f88c86708ec1f9dda865c77d77f251666289ecd164c82bd30db2e9743b624b91"

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
    To get started:

    1. Install and authenticate the GitHub CLI: brew install gh && gh auth login
    2. Launch from Applications or run: open /Applications/MacRunner.app
    3. Click the runner icon in the menu bar and add a runner
    4. Or use the CLI: mac-runner add owner/repo --name my-runner

    For help: https://github.com/omniaura/mac-runner
  EOS
end
