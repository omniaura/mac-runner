# Contributing to Mac Runner

## Commit Convention

We use [Conventional Commits](https://www.conventionalcommits.org/) for automatic semantic versioning.

### Commit Message Format

```
<type>: <description>

[optional body]

[optional footer]
```

### Types

- **feat:** A new feature (triggers MINOR version bump: 0.1.0 → 0.2.0)
- **fix:** A bug fix (triggers PATCH version bump: 0.1.0 → 0.1.1)
- **perf:** Performance improvement (triggers PATCH version bump)
- **revert:** Revert a previous commit (triggers PATCH version bump)
- **docs:** Documentation only (no release)
- **style:** Code style/formatting (no release)
- **refactor:** Code refactoring (no release)
- **test:** Adding/updating tests (no release)
- **chore:** Maintenance tasks (no release)
- **build:** Build system changes (no release)
- **ci:** CI/CD changes (no release)

### Examples

#### New Feature (Minor Release)
```bash
git commit -m "feat: add automatic pause on low battery

Runners now pause automatically when battery drops below 20%"
```
Result: 0.1.0 → 0.2.0

#### Bug Fix (Patch Release)
```bash
git commit -m "fix: prevent crash when GitHub token expires

Added token validation and graceful error handling"
```
Result: 0.1.0 → 0.1.1

#### Breaking Change (Major Release)
```bash
git commit -m "feat!: redesign configuration format

BREAKING CHANGE: Old config.json format is no longer supported.
Users must migrate to new format using migration tool."
```
Result: 0.1.0 → 1.0.0

#### No Release
```bash
git commit -m "docs: update README with installation instructions"
git commit -m "chore: update dependencies"
git commit -m "refactor: simplify runner manager code"
```
Result: No release

## How It Works

1. **Push to main** - Semantic-release analyzes commits since last release
2. **Determine version** - Based on commit types (feat/fix/etc)
3. **Generate CHANGELOG** - Automatic changelog from commits
4. **Build binaries** - Universal Mac app (arm64 + x86_64)
5. **Create release** - GitHub release with DMG and ZIP
6. **Update cask** - Homebrew formula with new SHA256

## Release Process

### Automatic (Recommended)

Just commit with proper convention and push to main:

```bash
git commit -m "feat: add daily check-in notifications"
git push origin main
```

GitHub Actions will:
- Determine next version (0.1.0 → 0.2.0)
- Build universal binary
- Create GitHub release v0.2.0
- Upload DMG and ZIP
- Update Homebrew cask
- Generate CHANGELOG.md

### Manual Release

If you need to trigger manually:

1. Go to Actions tab on GitHub
2. Select "Release" workflow
3. Click "Run workflow"
4. Select main branch
5. Click "Run"

## Development Workflow

1. **Create branch** for your feature
   ```bash
   git checkout -b feat/my-new-feature
   ```

2. **Make changes** and commit with convention
   ```bash
   git commit -m "feat: add runner health monitoring"
   ```

3. **Push and create PR**
   ```bash
   git push origin feat/my-new-feature
   ```

4. **Merge to main** - Release happens automatically!

## Testing Before Release

Build and test locally:

```bash
# Build
make build

# Run
make run

# Create app bundle
make app

# Test the bundle
open build/MacRunner.app
```

## Version Numbers

We follow [Semantic Versioning](https://semver.org/):

- **Major (1.0.0)** - Breaking changes
- **Minor (0.1.0)** - New features (backwards compatible)
- **Patch (0.0.1)** - Bug fixes (backwards compatible)

Examples:
- `feat:` → 0.1.0 → 0.2.0 (minor)
- `fix:` → 0.1.0 → 0.1.1 (patch)
- `feat!:` or `BREAKING CHANGE:` → 0.1.0 → 1.0.0 (major)

## First Release

To create v0.1.0:

```bash
# Tag manually
git tag v0.1.0 -m "First release"
git push origin v0.1.0
```

Or let semantic-release handle it:

```bash
git commit -m "feat: initial Mac Runner implementation"
git push origin main
```

## Questions?

Open an issue or check existing releases to see the format.
