# Changelog

## [0.5.0](https://github.com/icoretech/codex-action/compare/v0.4.0...v0.5.0) (2026-03-16)


### Features

* add network_access input to control network policy ([5dc4f26](https://github.com/icoretech/codex-action/commit/5dc4f2655b7b7f9f40acbf4887a0db8e5b4ea89d))

## [0.4.0](https://github.com/icoretech/codex-action/compare/v0.3.0...v0.4.0) (2026-03-16)


### Features

* auto-configure git safe.directory, add issue triage recipe ([a3eba5a](https://github.com/icoretech/codex-action/commit/a3eba5a82523ec682eb6ac9473df196714adf242))

## [0.3.0](https://github.com/icoretech/codex-action/compare/v0.2.1...v0.3.0) (2026-03-16)


### Features

* add codex_config_toml input for custom Codex preferences ([b6c8582](https://github.com/icoretech/codex-action/commit/b6c8582071c791d036ac2eedb2dcfcb27ef5b841))


### Bug Fixes

* write codex_config credentials to auth.json instead of config.toml ([d54880a](https://github.com/icoretech/codex-action/commit/d54880a0da5ad43ee72384d70afd4bc3feb76aec))

## [0.2.1](https://github.com/icoretech/codex-action/compare/v0.2.0...v0.2.1) (2026-03-16)


### Bug Fixes

* replace useless cat with input redirection (SC2002) ([5b7a20a](https://github.com/icoretech/codex-action/commit/5b7a20a3ca097e40fe7735c025f204db1442f386))

## [0.2.0](https://github.com/icoretech/codex-action/compare/v0.1.0...v0.2.0) (2026-03-16)


### Features

* add reasoning_effort input for controlling model reasoning level ([c014848](https://github.com/icoretech/codex-action/commit/c014848155e02c7a2b4edb2353a90109b8cc0a93))
* bump default codex-docker image to 0.114.0 ([3804705](https://github.com/icoretech/codex-action/commit/3804705170064073c4f0d39cefb38409f5ccd9dc))


### Bug Fixes

* chmod auth_dir so container user codex (uid 1000) can write to it ([1389078](https://github.com/icoretech/codex-action/commit/138907823c0bd0f980636a383cf5b37a898d1c0f))
* ensure trailing newline before GITHUB_OUTPUT delimiter and robust cleanup ([00c8c43](https://github.com/icoretech/codex-action/commit/00c8c43247875673d116a2e59bf4e9707168d07a))
* mount output directory instead of file for container write access ([db4100e](https://github.com/icoretech/codex-action/commit/db4100ec986b507a0f1793e07e14e2eda27ba1fe))
* use -o flag for output capture and fix container permissions ([2b828ba](https://github.com/icoretech/codex-action/commit/2b828ba26234581ef413ce9ee271e4669ab01af1))
* use correct config key model_reasoning_effort for reasoning effort ([6872bdc](https://github.com/icoretech/codex-action/commit/6872bdc4fda04855f263741ae1540484fe84f255))

## Changelog
