cask "mac-runner" do
  version "1.0.2"
  sha256 "cb96ed38a2efe66def332cee2e1e4081591e159c275df3eee0ae41d56d1f668b"

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
