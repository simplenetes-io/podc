# podc - Change log

## [0.4.0 - 2021-04-08]

+ Add CHANGELOG.md :)

+ Add support for `network: host`

+ Add cmd line option (-e/--source-env) to allow missing variables to be sourced from environment

- Remove expose section for runtime executable

* Add `lsof` to podman runtime to check for busy ports, do not fail if program non existing

* Update pod API spec to 1.0.0-beta2

* Allow config volumes names to begin with underscore

* Allow compiler to be backwards compatible

* Rename release/podman-runtime-<api-version> to release/podc-podman-runtime, since backwards compatible now

* Upgrade network module dependency to 2.1.0
