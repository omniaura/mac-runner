cask "mac-runner" do
  version "1.0.1"
  sha256 "0bf25277a8abbf2347b2ba77c1689cef2e8acd9259668f036e220d26003e0b09"

  url "https://github.com/omniaura/mac-runner/releases/download/v#{version}/MacRunner-#{version}.zip"
  name "Mac Runner"
  desc "Menu bar app for managing GitHub Actions self-hosted runners"
  homepage "https://github.com/omniaura/mac-runner"

  depends_on macos: ">= :ventura"

  app "MacRunner.app"

  zap trash: [
    "~/Library/Application Support/MacRunner",
    "~/Library/Preferences/com.omniaura.mac-runner.plist",
  ]

  caveats <<~EOS
    To get started:

    1. Launch from Applications or run: open -a "Mac Runner"
    2. Click the runner icon in the menu bar
    3. Add your GitHub repos with a PAT token
    4. Runners will be automatically configured!

    For help: https://github.com/omniaura/mac-runner
  EOS
end
