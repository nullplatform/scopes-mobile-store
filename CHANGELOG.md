# Changelog

## [0.4.0](https://github.com/nullplatform/scopes-mobile-store/compare/v0.3.0...v0.4.0) (2026-10-13)


### Features

* **mobile-store:** assume the scope IAM role before AWS calls ([a92572e](https://github.com/nullplatform/scopes-mobile-store/commit/a92572ebf60d77e05a0973927ed12739dab30837))
* **mobile-store:** wire deployment, scope and instance workflows ([031a31e](https://github.com/nullplatform/scopes-mobile-store/commit/031a31e6f8873638880777cff65dce01452d5e2c))


### Bug Fixes

* **mobile-store:** address the remaining layer review findings ([b86c53f](https://github.com/nullplatform/scopes-mobile-store/commit/b86c53fe8df80a2694ecfc8c16f4b4e1ee67f6c8))
* **mobile-store:** address workflow review findings ([950b41b](https://github.com/nullplatform/scopes-mobile-store/commit/950b41b43a1dd1aab1a59cce9582e55b70a352d0))
* **mobile-store:** answer instance:data only for telemetry requests ([24bd99f](https://github.com/nullplatform/scopes-mobile-store/commit/24bd99fa7d4a91122e09a9b8495a18bd83df2d55))
* **mobile-store:** isolate instance workdirs and let rollbacks skip current assets ([d08b28e](https://github.com/nullplatform/scopes-mobile-store/commit/d08b28e40e6afd8a02db6e43e43e0424aff0479e))

## [0.3.0](https://github.com/nullplatform/scopes-mobile-store/compare/v0.2.0...v0.3.0) (2026-10-13)


### Features

* **mobile-store:** add android, signing, firebase and gate layers ([709573e](https://github.com/nullplatform/scopes-mobile-store/commit/709573e6e5b348892295d134c3b030ea14038174))
* **mobile-store:** add distribution tooling to the worker image ([243b319](https://github.com/nullplatform/scopes-mobile-store/commit/243b3198bef67c94eadd61b40e38a91cbd5e8ba3))
* **mobile-store:** add the AWS IAM requirements module for the agent ([12687d8](https://github.com/nullplatform/scopes-mobile-store/commit/12687d823fc91e6e5bce5ee87736cc785a978db8))


### Bug Fixes

* **mobile-store:** avoid SIGPIPE when validating large binaries ([d117111](https://github.com/nullplatform/scopes-mobile-store/commit/d117111d4aba01d676281b3e776d8ef5831149ac))
* **mobile-store:** enforce the approval gate for production on public stores ([8f0c514](https://github.com/nullplatform/scopes-mobile-store/commit/8f0c5140f2330291ec991f6d54a968482831d963))
* **mobile-store:** harden credentials, network calls and partial distributions ([07aecb5](https://github.com/nullplatform/scopes-mobile-store/commit/07aecb5e90a08c267f96fdf475a97db4e53f86a0))
* **mobile-store:** make the production approval gate fail closed ([2ffe808](https://github.com/nullplatform/scopes-mobile-store/commit/2ffe80823c3058b66d257c862d53f23fd200dfb9))
* **mobile-store:** restrict secrets, asset sources and Firebase ids to the configured scope ([1e761fd](https://github.com/nullplatform/scopes-mobile-store/commit/1e761fd169fee5013c9d6f8f06e75ff9c2fa3520))

## [0.2.0](https://github.com/nullplatform/scopes-mobile-store/compare/v0.1.2...v0.2.0) (2026-10-13)


### Features

* **mobile-store:** add build_context and layer executor ([34c9ec4](https://github.com/nullplatform/scopes-mobile-store/commit/34c9ec4e06d18d08fb3345bdb327d2f0a25944f8))


### Bug Fixes

* **mobile-store:** address the build_context re-review follow-ups ([a4b8af8](https://github.com/nullplatform/scopes-mobile-store/commit/a4b8af8457df8169cadeba9acdba29c639cee569))
* **mobile-store:** pick the previous deployment by real status and harden the lookups ([a0e7247](https://github.com/nullplatform/scopes-mobile-store/commit/a0e72473d8cfe05b827f5aab6fe7109492f6660f))
* **mobile-store:** stop relying on asset metadata for version and package ([36a3cbb](https://github.com/nullplatform/scopes-mobile-store/commit/36a3cbb6fc1e7e5b72c45fd6080d2427b03f7dfd))
* **mobile-store:** validate layer and context inputs before building paths ([b850c95](https://github.com/nullplatform/scopes-mobile-store/commit/b850c952e4ad84dc69c70f1573def6c2c858d5db))

## [0.1.2](https://github.com/nullplatform/scopes-mobile-store/compare/v0.1.1...v0.1.2) (2026-10-13)


### Bug Fixes

* **ci:** publish the worker image under agent-plugins/scopes/mobile-store as the template defines ([6d3321c](https://github.com/nullplatform/scopes-mobile-store/commit/6d3321c911b5100f9f0f2b453b6acfbe4375bbb8))

## [0.1.1](https://github.com/nullplatform/scopes-mobile-store/compare/v0.1.0...v0.1.1) (2026-10-13)


### Bug Fixes

* **ci:** push the worker image to the scopes/mobile-store ECR Public repository ([1d82142](https://github.com/nullplatform/scopes-mobile-store/commit/1d8214285824de8f2b376ba3459369970c72a6a6))

## [0.1.0](https://github.com/nullplatform/scopes-mobile-store/compare/v1.0.0...v0.1.0) (2026-10-13)


### Miscellaneous Chores

* **mobile-store:** use the bundle asset type and record A1/A2 in the ledger ([8af096a](https://github.com/nullplatform/scopes-mobile-store/commit/8af096ae7db78faaa4cb97bea1bf05a2f0bae0a8))

## 1.0.0 (2026-10-13)


### Features

* **mobile-store:** declare the mobile-binary asset type the scope deploys ([774a33c](https://github.com/nullplatform/scopes-mobile-store/commit/774a33ca09606d80305c59a9085a463dab6991f4))
* **mobile-store:** define developer capabilities and scope configuration schema ([688479e](https://github.com/nullplatform/scopes-mobile-store/commit/688479e4d3430f40a578393a0ece2acb95e0a2a9))


### Bug Fixes

* **mobile-store:** drop platform layer from scope configuration and tighten spec tests ([2b34d29](https://github.com/nullplatform/scopes-mobile-store/commit/2b34d29e9caaa6feb832f598acd58ce095547b06))

## Changelog
