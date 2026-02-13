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
