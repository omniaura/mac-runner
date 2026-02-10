# How to Release Mac Runner

## Quick Start

Mac Runner uses semantic-release for automated versioning and releases.

### Step 1: Add the Workflow to GitHub

The workflow file `release-workflow.yml` needs to be added to `.github/workflows/`:

**Option A: Via GitHub Web UI**
1. Go to https://github.com/omniaura/mac-runner
2. Create new file: `.github/workflows/release.yml`
3. Copy content from `release-workflow.yml`
4. Commit to main

**Option B: With proper PAT**
```bash
# Get PAT with 'workflow' scope from https://github.com/settings/tokens
export GITHUB_TOKEN="your_token_with_workflow_scope"
gh auth login --with-token <<< $GITHUB_TOKEN

# Move the workflow file
mkdir -p .github/workflows
mv release-workflow.yml .github/workflows/release.yml
git add .github/workflows/release.yml
git commit -m "ci: add semantic release workflow"
git push origin main
```

### Step 2: Make Your First Release

Just commit with conventional commit format:

```bash
git commit -m "feat: initial Mac Runner implementation"
git push origin main
```

Semantic-release will:
- Analyze commits (sees `feat:`)
- Determine version: 0.1.0
- Build universal binary
- Create GitHub release v0.1.0
- Upload DMG and ZIP
- Update Homebrew cask
- Generate CHANGELOG.md

### Step 3: Users Can Install

```bash
brew tap omniaura/tap https://github.com/omniaura/mac-runner
brew install --cask mac-runner
```

## How It Works

### Commit Types → Versions

| Commit Type | Example | Version Change |
|-------------|---------|----------------|
| `feat:` | `feat: add notifications` | 0.1.0 → 0.2.0 (minor) |
| `fix:` | `fix: runner crash` | 0.1.0 → 0.1.1 (patch) |
| `feat!:` | `feat!: new config format` | 0.1.0 → 1.0.0 (major) |
| `docs:` | `docs: update README` | No release |
| `chore:` | `chore: update deps` | No release |

### Workflow Trigger

Pushes to `main` branch trigger the workflow. It:

1. **Analyzes commits** since last release
2. **Determines version** based on commit types
3. **Builds app** (if new version needed)
   - Universal binary (arm64 + x86_64)
   - App bundle with Info.plist
   - ZIP for Homebrew
   - DMG for direct download
4. **Creates release** on GitHub
5. **Updates cask** with new SHA256
6. **Generates CHANGELOG**

### No Release Needed?

If only `docs:`, `chore:`, `refactor:` commits, no release is created.

## Examples

### New Feature
```bash
git commit -m "feat: add pause on low battery

Automatically pauses all runners when battery drops below 20%"
git push origin main
```
→ Creates v0.2.0

### Bug Fix
```bash
git commit -m "fix: prevent token expiration crash

Added validation and better error handling"
git push origin main
```
→ Creates v0.1.1

### Multiple Changes
```bash
git commit -m "feat: add daily check-ins"
git commit -m "fix: memory leak in runner monitor"
git commit -m "docs: update installation guide"
git push origin main
```
→ Creates v0.2.0 (highest precedence: feat > fix > docs)

### Breaking Change
```bash
git commit -m "feat!: redesign runner configuration

BREAKING CHANGE: Config format changed from JSON to YAML.
See migration guide for details."
git push origin main
```
→ Creates v1.0.0

## Manual Release

If you need to release without semantic-release:

```bash
# Tag manually
git tag -a v0.1.0 -m "First release"
git push origin v0.1.0

# Then manually trigger workflow via GitHub Actions UI
```

## Troubleshooting

### "No release needed"

- Make sure you're using `feat:` or `fix:` commits
- Check if there are commits since last release
- `docs:`, `chore:` etc. don't trigger releases

### Workflow not running

- Verify workflow file is at `.github/workflows/release.yml`
- Check Actions tab on GitHub for errors
- Ensure you pushed to `main` branch

### Build fails

- Check Swift package resolves: `swift package resolve`
- Verify Xcode compatibility
- Check GitHub Actions logs

### Cask not updating

- Workflow should automatically update cask
- Check if git push succeeded in workflow logs
- May need to manually update SHA256

## Current Status

✅ Semantic-release configured
✅ Release workflow created
✅ Homebrew cask ready
⏳ Need to add workflow to GitHub
⏳ Ready for first release!

## Next Steps

1. Add `release-workflow.yml` to `.github/workflows/release.yml` on GitHub
2. Commit a feat: to trigger first release
3. Wait ~5 minutes for build
4. Install via Homebrew!

```bash
brew tap omniaura/tap https://github.com/omniaura/mac-runner
brew install --cask mac-runner
```
