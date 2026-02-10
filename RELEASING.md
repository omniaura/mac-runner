# Releasing Mac Runner

## Automated Release Process

Releases are automated via GitHub Actions. Just push a tag:

```bash
# Create and push a new version tag
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

The GitHub Action will:
1. Build universal binary (arm64 + x86_64)
2. Create app bundle
3. Generate DMG
4. Create ZIP for Homebrew
5. Create GitHub release with artifacts
6. Update Homebrew formula automatically

## Manual Release Process

If you need to release manually:

### 1. Build Release Binary

```bash
make release
```

### 2. Create App Bundle

```bash
make app
```

### 3. Create DMG

```bash
make dmg
```

### 4. Create ZIP for Homebrew

```bash
cd build
zip -r MacRunner-0.1.0.zip MacRunner.app
shasum -a 256 MacRunner-0.1.0.zip
```

### 5. Create GitHub Release

```bash
gh release create v0.1.0 \
  --title "Mac Runner v0.1.0" \
  --notes "Release notes here" \
  build/MacRunner-0.1.0.dmg \
  build/MacRunner-0.1.0.zip
```

### 6. Update Homebrew Formula

Edit `Formula/mac-runner.rb`:

```ruby
class MacRunner < Formula
  desc "Menu bar app for managing GitHub Actions self-hosted runners"
  homepage "https://github.com/omniaura/mac-runner"
  url "https://github.com/omniaura/mac-runner/releases/download/v0.1.0/MacRunner-0.1.0.zip"
  sha256 "YOUR_SHA256_HERE"
  version "0.1.0"
  # ...
end
```

Commit and push:

```bash
git add Formula/mac-runner.rb
git commit -m "Update Homebrew formula to v0.1.0"
git push origin main
```

## Version Numbering

We use semantic versioning:

- **Major** (1.0.0): Breaking changes, major features
- **Minor** (0.1.0): New features, backwards compatible
- **Patch** (0.1.1): Bug fixes, minor improvements

## Pre-Release Checklist

Before tagging a release:

- [ ] All tests pass: `make test`
- [ ] Code builds without warnings: `make build`
- [ ] README is up to date
- [ ] CHANGELOG is updated
- [ ] Version numbers are consistent
- [ ] Test the app manually
- [ ] Check Homebrew formula syntax

## Post-Release

After release is published:

1. Test Homebrew installation:
   ```bash
   brew tap omniaura/tap https://github.com/omniaura/mac-runner
   brew install --cask mac-runner
   ```

2. Verify the app launches and works

3. Announce on social media / Discord / etc.

4. Update any documentation that references version numbers

## Troubleshooting

### Build fails on GitHub Actions

- Check Xcode version compatibility
- Verify Package.swift dependencies
- Check for missing code signing certificates

### Homebrew formula issues

- Verify SHA256 matches the ZIP file
- Check URL is accessible
- Test formula locally: `brew install --build-from-source Formula/mac-runner.rb`

### DMG creation fails

Falls back to simple hdiutil DMG if create-dmg fails. This is normal and acceptable.

## Code Signing (Optional)

For distributing outside the App Store, you'll want to code sign:

1. Get a Developer ID certificate from Apple
2. Add to GitHub Secrets:
   - `MACOS_CERTIFICATE` (base64 encoded .p12)
   - `MACOS_CERTIFICATE_PWD` (password)
   - `MACOS_CERTIFICATE_NAME` (certificate name)

3. GitHub Action will automatically sign if secrets are present

## Notarization (Future)

For Gatekeeper compatibility:

1. Sign the app
2. Create DMG
3. Submit to Apple for notarization
4. Staple the notarization ticket

This will be automated in a future release.
