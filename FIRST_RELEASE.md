# Creating the First Release

The cask is set up but needs an actual release with binaries. Here's how to create v0.1.0:

## Option 1: Automated (Recommended)

**Once GitHub Actions workflow is added:**

```bash
git tag -a v0.1.0 -m "First release"
git push origin v0.1.0
```

The workflow will:
- Build universal binary
- Create app bundle
- Generate DMG and ZIP
- Create GitHub release
- Update cask SHA256

## Option 2: Manual Build on Mac

**Build the app:**

```bash
# Build release binary
make release

# Create app bundle
make app

# Create ZIP for Homebrew
cd build
zip -r MacRunner-0.1.0.zip MacRunner.app

# Get SHA256
shasum -a 256 MacRunner-0.1.0.zip
```

**Create release:**

```bash
gh release create v0.1.0 \
  --title "Mac Runner v0.1.0" \
  --notes "First release of Mac Runner - automated GitHub Actions runner management" \
  build/MacRunner-0.1.0.zip
```

**Update cask with SHA256:**

Edit `Casks/mac-runner.rb`:
```ruby
sha256 "YOUR_ACTUAL_SHA256_HERE"  # Replace :no_check
```

Commit and push:
```bash
git add Casks/mac-runner.rb
git commit -m "Update cask SHA256 for v0.1.0"
git push origin main
```

## Testing the Install

After release is published:

```bash
# Update tap
brew update

# Install
brew install --cask mac-runner

# Run
open -a "Mac Runner"
```

## GitHub Actions Workflow

To add the workflow (needs PAT with workflow scope):

1. Go to https://github.com/omniaura/mac-runner/new/main/.github/workflows
2. Name: `release.yml`
3. Copy content from `.github/workflows/release.yml` in git history
4. Commit directly to main

Or regenerate it and upload manually.

## Current Status

- ✅ Code complete
- ✅ Cask formula ready
- ✅ Makefile for building
- ⏳ Need to build and release v0.1.0
- ⏳ Need to add GitHub Actions workflow

Once v0.1.0 is released, users can install via Homebrew!
