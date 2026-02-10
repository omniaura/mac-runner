class MacRunner < Formula
  desc "Menu bar app for managing GitHub Actions self-hosted runners"
  homepage "https://github.com/omniaura/mac-runner"
  url "https://github.com/omniaura/mac-runner/releases/download/v0.1.0/MacRunner-0.1.0.zip"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  version "0.1.0"

  depends_on :macos

  def install
    prefix.install "MacRunner.app"
  end

  def caveats
    <<~EOS
      Mac Runner has been installed to:
        #{prefix}/MacRunner.app

      To start Mac Runner:
        open #{prefix}/MacRunner.app

      Or run from anywhere:
        open -a "Mac Runner"

      To run at login, add Mac Runner to your Login Items in System Preferences.

      For first-time setup, you'll need a GitHub Personal Access Token with 'repo' scope.
      Create one at: https://github.com/settings/tokens
    EOS
  end

  test do
    assert_predicate prefix/"MacRunner.app", :exist?
  end
end
