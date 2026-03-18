## [1.12.1](https://github.com/omniaura/mac-runner/compare/v1.12.0...v1.12.1) (2026-03-18)


### Bug Fixes

* resolve CLI version when invoked without full path ([#63](https://github.com/omniaura/mac-runner/issues/63)) ([d69a1da](https://github.com/omniaura/mac-runner/commit/d69a1da8535c70a96fa5d0b503c2680c0bd4ba9b))

# [1.12.0](https://github.com/omniaura/mac-runner/compare/v1.11.1...v1.12.0) (2026-03-18)


### Features

* add cached app update checks ([#61](https://github.com/omniaura/mac-runner/issues/61)) ([0133913](https://github.com/omniaura/mac-runner/commit/0133913f5d5b7dc7caf09abcc100e9d68a4b1e1a))

## [1.11.1](https://github.com/omniaura/mac-runner/compare/v1.11.0...v1.11.1) (2026-03-17)


### Bug Fixes

* read CLI version from the installed app bundle ([#60](https://github.com/omniaura/mac-runner/issues/60)) ([ee3dc5d](https://github.com/omniaura/mac-runner/commit/ee3dc5d032686c8a16e4ebc5f0c0b0d0764c5df5))

# [1.11.0](https://github.com/omniaura/mac-runner/compare/v1.10.2...v1.11.0) (2026-03-16)


### Features

* add configurable open file limits ([#59](https://github.com/omniaura/mac-runner/issues/59)) ([ccf366f](https://github.com/omniaura/mac-runner/commit/ccf366feb5224a453a21ee197f4bbae8561d2c74))
* auto-restart runners after unexpected exits ([#52](https://github.com/omniaura/mac-runner/issues/52)) ([39af616](https://github.com/omniaura/mac-runner/commit/39af61643e7524116f37bf7500d80c19a53c66b1))

## [1.10.2](https://github.com/omniaura/mac-runner/compare/v1.10.1...v1.10.2) (2026-03-16)


### Bug Fixes

* pin release runs to their triggering commit ([#58](https://github.com/omniaura/mac-runner/issues/58)) ([4d3dbd8](https://github.com/omniaura/mac-runner/commit/4d3dbd88663cc1c4e57583c347a3fa6207376416))

## [1.10.1](https://github.com/omniaura/mac-runner/compare/v1.10.0...v1.10.1) (2026-03-16)


### Bug Fixes

* clean up macOS startup and launch guidance ([#56](https://github.com/omniaura/mac-runner/issues/56)) ([0b1169a](https://github.com/omniaura/mac-runner/commit/0b1169a6e4bdfb04b2b9fc04e26cb916cb6766c6))
* reconcile Launch at Login checkbox with macOS system state ([#57](https://github.com/omniaura/mac-runner/issues/57)) ([2da139f](https://github.com/omniaura/mac-runner/commit/2da139fa13fe40fbf478d81392745945ce2aa125))

# [1.10.0](https://github.com/omniaura/mac-runner/compare/v1.9.0...v1.10.0) (2026-03-16)


### Bug Fixes

* correct signing identity name and simplify Homebrew install ([3cb33f4](https://github.com/omniaura/mac-runner/commit/3cb33f4a1c9124c9760b316d2b57672799a1cfcd))


### Features

* add code signing and notarization to release workflow ([#55](https://github.com/omniaura/mac-runner/issues/55)) ([da50fc2](https://github.com/omniaura/mac-runner/commit/da50fc2abdf47cdd143bb299ced56460d0374e2a))

# [1.9.0](https://github.com/omniaura/mac-runner/compare/v1.8.1...v1.9.0) (2026-03-16)


### Features

* group runners by org/repo in menubar dropdown ([#49](https://github.com/omniaura/mac-runner/issues/49)) ([222633d](https://github.com/omniaura/mac-runner/commit/222633d80e7474611fb533d17693ce4bab977a40)), closes [#19](https://github.com/omniaura/mac-runner/issues/19)

## [1.8.1](https://github.com/omniaura/mac-runner/compare/v1.8.0...v1.8.1) (2026-03-04)


### Bug Fixes

* resolve duplicate runner naming race condition and add bulk creation ([#17](https://github.com/omniaura/mac-runner/issues/17)) ([#45](https://github.com/omniaura/mac-runner/issues/45)) ([28d7900](https://github.com/omniaura/mac-runner/commit/28d790062b99f02a0c15cc72f5d7f0ebc032e40e))

# [1.8.0](https://github.com/omniaura/mac-runner/compare/v1.7.2...v1.8.0) (2026-03-03)


### Features

* include org repos in Browse picker with search and grouping ([#38](https://github.com/omniaura/mac-runner/issues/38)) ([6fa5173](https://github.com/omniaura/mac-runner/commit/6fa51738866951e2ecdffa00a2d8a3c17cefb5af)), closes [#37](https://github.com/omniaura/mac-runner/issues/37)

## [1.7.2](https://github.com/omniaura/mac-runner/compare/v1.7.1...v1.7.2) (2026-02-23)


### Bug Fixes

* increase file descriptor limit to 65536 for runner processes ([#34](https://github.com/omniaura/mac-runner/issues/34)) ([297846e](https://github.com/omniaura/mac-runner/commit/297846e157212ab15cb666fd4ab56be96976297f)), closes [#32](https://github.com/omniaura/mac-runner/issues/32)

## [1.7.1](https://github.com/omniaura/mac-runner/compare/v1.7.0...v1.7.1) (2026-02-23)


### Bug Fixes

* set TMPDIR for service user to fix oxfmt DataCloneError ([#35](https://github.com/omniaura/mac-runner/issues/35)) ([bce2e39](https://github.com/omniaura/mac-runner/commit/bce2e3969d2732720fb5401df8e810eb9de2af4e)), closes [#33](https://github.com/omniaura/mac-runner/issues/33)

# [1.7.0](https://github.com/omniaura/mac-runner/compare/v1.6.2...v1.7.0) (2026-02-17)


### Features

* add headless mode (default) with optional GUI access ([#28](https://github.com/omniaura/mac-runner/issues/28)) ([f22c47e](https://github.com/omniaura/mac-runner/commit/f22c47ed6e471402ac22c69bd5ca576500c42ed5))

## [Unreleased]

### Features

* **headless mode:** runners now default to headless (no GUI access) for better isolation and performance
  - Add `--enable-gui` CLI flag to opt-in to GUI access when needed (visual tests, Xcode UI tests)
  - GUI toggle in Add Runner dialog
  - GUI access status displayed in CLI `list` and menu bar
  - Headless mode removes DISPLAY and GUI-related environment variables

## [1.6.2](https://github.com/omniaura/mac-runner/compare/v1.6.1...v1.6.2) (2026-02-17)


### Bug Fixes

* disable SPM sandbox to resolve unsafe build flags error ([cf54025](https://github.com/omniaura/mac-runner/commit/cf540257161eb8ceed72d5a8ada206ab21228d38)), closes [#15](https://github.com/omniaura/mac-runner/issues/15) [#18](https://github.com/omniaura/mac-runner/issues/18)
* update CLI version to 1.6.0 to match current release ([eeeff07](https://github.com/omniaura/mac-runner/commit/eeeff070ac63d7409998d638624ebb1506d15a14)), closes [#29](https://github.com/omniaura/mac-runner/issues/29)

## [1.6.1](https://github.com/omniaura/mac-runner/compare/v1.6.0...v1.6.1) (2026-02-16)


### Bug Fixes

* show effective isolation mode in CLI list output ([#25](https://github.com/omniaura/mac-runner/issues/25)) ([8c4c786](https://github.com/omniaura/mac-runner/commit/8c4c786803ac0bb3ad63e6625a072f476dfc0f31))

# [1.6.0](https://github.com/omniaura/mac-runner/compare/v1.5.0...v1.6.0) (2026-02-15)


### Features

* Add hybrid isolation strategy with Apple container support ([#12](https://github.com/omniaura/mac-runner/issues/12)) ([7c00591](https://github.com/omniaura/mac-runner/commit/7c0059155b800b600daca058f7bffc9df50022db)), closes [#9](https://github.com/omniaura/mac-runner/issues/9) [#9](https://github.com/omniaura/mac-runner/issues/9) [#9](https://github.com/omniaura/mac-runner/issues/9)

# [1.5.0](https://github.com/omniaura/mac-runner/compare/v1.4.0...v1.5.0) (2026-02-14)


### Bug Fixes

* resolve build errors from container isolation and Xcode 26 SDK ([#13](https://github.com/omniaura/mac-runner/issues/13)) ([1a7bc29](https://github.com/omniaura/mac-runner/commit/1a7bc291dd3913d3999c1a2c538520741fa46019))


### Features

* add container isolation infrastructure (Phase 1) ([4692fdf](https://github.com/omniaura/mac-runner/commit/4692fdfc0196c75c4f01c3b704403c4524fbc730)), closes [#9](https://github.com/omniaura/mac-runner/issues/9) [#9](https://github.com/omniaura/mac-runner/issues/9)
* add launch on login and auto-restart runners ([#10](https://github.com/omniaura/mac-runner/issues/10)) ([99b4916](https://github.com/omniaura/mac-runner/commit/99b49169bef58daef974adbdf89e5318559a0d78))
* implement Phase 3 container lifecycle service for hybrid isolation ([903849c](https://github.com/omniaura/mac-runner/commit/903849cf7779f45dc66d74ea2064d948386c54b7)), closes [#9](https://github.com/omniaura/mac-runner/issues/9) [#9](https://github.com/omniaura/mac-runner/issues/9)

# [1.4.0](https://github.com/omniaura/mac-runner/compare/v1.3.0...v1.4.0) (2026-02-13)


### Features

* add runner execution status and duplicate functionality ([caa37d0](https://github.com/omniaura/mac-runner/commit/caa37d0cc9afb2cc06468a3198f38ccf500935c0))

# [1.3.0](https://github.com/omniaura/mac-runner/compare/v1.2.0...v1.3.0) (2026-02-13)


### Features

* add dedicated user isolation for self-hosted runners ([#7](https://github.com/omniaura/mac-runner/issues/7)) ([ff65794](https://github.com/omniaura/mac-runner/commit/ff6579467343c415638da8cbb4f2264dd4922a74))

# [1.2.0](https://github.com/omniaura/mac-runner/compare/v1.1.4...v1.2.0) (2026-02-10)


### Features

* symlink mac-runner CLI to PATH via Homebrew cask ([4cae272](https://github.com/omniaura/mac-runner/commit/4cae27258b55c601a8b75ef8693f2c3e0f5bfee9))

## [1.1.4](https://github.com/omniaura/mac-runner/compare/v1.1.3...v1.1.4) (2026-02-10)


### Bug Fixes

* **ci:** add Homebrew PATH and setup-node to check-release job ([09b5fca](https://github.com/omniaura/mac-runner/commit/09b5fcaa676852137cc258c635393c9fc46a1a2d))

## [1.1.3](https://github.com/omniaura/mac-runner/compare/v1.1.2...v1.1.3) (2026-02-10)


### Bug Fixes

* **ci:** add administration:read permission for runner fallback ([1d229a9](https://github.com/omniaura/mac-runner/commit/1d229a92ed2b7f3cd7b11fab8cf52029c07c8e2a))
* **ci:** add Homebrew to PATH for self-hosted runner ([54146ba](https://github.com/omniaura/mac-runner/commit/54146baf03c5d3bd92625d417c3e28c583a5effb))
* **ci:** use mac-runner directly, remove runner-fallback-action ([6479203](https://github.com/omniaura/mac-runner/commit/6479203e452bd2ef9cef8cd35e0d87bd18487ba9))
* **ci:** use RUNNER_TOKEN for runner-fallback-action ([d1e99c8](https://github.com/omniaura/mac-runner/commit/d1e99c8e66df7a8fcf25f0d27abe489451e5049d))

## [1.1.2](https://github.com/omniaura/mac-runner/compare/v1.1.1...v1.1.2) (2026-02-10)


### Bug Fixes

* settings button opens settings window ([#6](https://github.com/omniaura/mac-runner/issues/6)) ([65b6e9e](https://github.com/omniaura/mac-runner/commit/65b6e9e1e965ded86bb40efb7ee06d556228d9a6))

## [1.1.1](https://github.com/omniaura/mac-runner/compare/v1.1.0...v1.1.1) (2026-02-10)


### Bug Fixes

* update cask caveats for gh CLI ([#5](https://github.com/omniaura/mac-runner/issues/5)) ([3ec611e](https://github.com/omniaura/mac-runner/commit/3ec611ee3111a4f348ad92d81e49bb8cc5ab6bec))

# [1.1.0](https://github.com/omniaura/mac-runner/compare/v1.0.2...v1.1.0) (2026-02-10)


### Bug Fixes

* move runner directory to ~/.mac-runner to avoid spaces in path ([a9d64eb](https://github.com/omniaura/mac-runner/commit/a9d64ebc54eb9a086df39fcbfe4f71b2ce1d7b00))


### Features

* gh CLI integration, dual CLI+GUI, self-hosted runner support ([6320419](https://github.com/omniaura/mac-runner/commit/6320419206f87a08dc0b915a34a9d2db8c0935b6))

## [1.0.2](https://github.com/omniaura/mac-runner/compare/v1.0.1...v1.0.2) (2026-02-10)


### Bug Fixes

* inject RunnerManager into popover to prevent crash on click ([885e470](https://github.com/omniaura/mac-runner/commit/885e47023264d4166bb504a81377547d42237452))

## [1.0.1](https://github.com/omniaura/mac-runner/compare/v1.0.0...v1.0.1) (2026-02-10)


### Bug Fixes

* **ci:** stash cask changes before git pull in release workflow ([ccff4f5](https://github.com/omniaura/mac-runner/commit/ccff4f5331c982abd77d46e025ede78ee2b63002))
* **ci:** sync with remote before semantic-release to prevent race condition ([e4daa2d](https://github.com/omniaura/mac-runner/commit/e4daa2d013d43649ab970c3e395492176841f8e5))

# 1.0.0 (2026-02-10)


### Features

* add semantic-release automation ([3f7c9c1](https://github.com/omniaura/mac-runner/commit/3f7c9c172f2a7535cf04018b15039eff74222335))
* initial Mac Runner release ([e962360](https://github.com/omniaura/mac-runner/commit/e9623605db310cf64eb9f75128718cf4334a5e5c))
