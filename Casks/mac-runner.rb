cask "mac-runner" do
  version "1.0.0"
  sha256 "52a7a70b8571eabaac84cb4920f21c0af4dc72fef4e8f28bcc2b8dffa04d01e8"

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
    Mac Runner is in early development. To use:

    1. Launch from Applications
    2. Click the runner icon in menu bar
    3. Add your GitHub repos with PAT token
    4. Runners will be automatically configured!

    Note: First release pending. The app will be available after v0.1.0 is published.
  EOS
end
