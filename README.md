# Weaver

https://github.com/open-telemetry/weaver

This fork publishes prebuilt weaver binaries for the platforms upstream does not
release (linux ppc64le, linux s390x, windows x86_64). The mongo repository consumes
these tarballs through its `@weaver_binary` Bazel repository rule
(`buildscripts/bazel_rules_mongo/weaver/weaver_binary.bzl`) to generate typed tracing
span sources at build time.

## Building new binaries

`scripts/build_weaver_binaries.sh` is self-contained: it installs the pinned Rust
toolchain (weaver's `rust-toolchain.toml` version) and cross toolchains, builds every
target, verifies that each runnable target produces byte-identical output from the
fixture registry in `ci/fixture` (windows binaries are packaged but must be verified on
a windows host — see the `verify_weaver_windows` task), and writes release tarballs to
`release/` with a `SHA256SUMS` file.

1. Run the script (Ubuntu 22.04, ~30 min), or the `build_weaver_binaries` Evergreen task.
2. Verify the windows binary: publish a release with the tarballs, then run the
   `verify_weaver_windows` task (or a Windows host) against it.
3. Publish a release on this repository tagged `v<weaver-version>-mdb.<n>` and attach
   the tarballs.
4. Pin the new sha256 values in the mongo repository's `weaver_binary.bzl`.

Upgrading the pinned weaver version means bumping `WEAVER_VERSION` (and the source
tarball sha) in `scripts/build_weaver_binaries.sh` and repeating the four steps.

## Evergreen

`evergreen.yml` defines the `build_weaver_binaries` and `verify_weaver_windows` tasks
and their patch-only variants. The project must be registered with Evergreen before
these run there; until then the tasks run via the mongo repository's own patch builds
or manually on a linux host.
