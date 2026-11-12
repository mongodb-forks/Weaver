#!/usr/bin/env bash
#
# Builds Weaver CLI binaries for the platforms upstream (open-telemetry/weaver) does not
# publish: linux ppc64le, linux s390x, and windows x86_64, and packages them as release
# tarballs for the mongo repository's @weaver_binary repository rule
# (buildscripts/bazel_rules_mongo/weaver/weaver_binary.bzl).
#
# The binaries are verified self-contained: every runnable target generates output from
# the fixture registry under ci/fixture (checked in, so this repo has no dependency on
# the mongo repo) and all outputs must be byte-identical to the official x86_64 build's
# output. Windows binaries are packaged but not executed here; use the
# verify_weaver_windows Evergreen task on a windows host after publishing a release.
#
# Run from the root of a checkout of this repository. Requires: Ubuntu 22.04 (apt),
# network access, ~10GB free disk, ~30 minutes.

set -o errexit
set -o pipefail
set -o xtrace

WEAVER_VERSION="0.28.0"
RUST_VERSION="1.96.1"

SOURCE_URL="https://github.com/open-telemetry/weaver/releases/download/v${WEAVER_VERSION}/source.tar.gz"
SOURCE_SHA256="a4dffcf73d20172a9031e20d22162edf933c15f3b6ab11bd2f5ff13e8ae5d795"
REFERENCE_URL="https://github.com/open-telemetry/weaver/releases/download/v${WEAVER_VERSION}/weaver-x86_64-unknown-linux-musl.tar.xz"
REFERENCE_SHA256="69069769ec3509c358ddbfbc29ff9965590fe4f8dd8b03e1c1e1be1ae56122e8"

# Cross targets: triple -> crypto feature flags. ring (the default backend) has no
# big-endian port, so s390x uses the vendored OpenSSL backend instead.
TARGETS=(
    "powerpc64le-unknown-linux-gnu|"
    "s390x-unknown-linux-gnu|--no-default-features --features crypto-openssl-vendored"
    "x86_64-pc-windows-gnu|"
)

WORKDIR="$(pwd)/build"
OUTDIR="$(pwd)/release"
FIXTURE_DIR="$(pwd)/ci/fixture"

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR" "$OUTDIR"

log() {
    echo "=================================================================="
    echo "== $*"
}

install_toolchain() {
    log "Installing Rust ${RUST_VERSION} and cross targets"
    if ! command -v rustup >/dev/null; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --default-toolchain "${RUST_VERSION}" --profile minimal
    fi
    rustup toolchain install "${RUST_VERSION}" --profile minimal
    for target in powerpc64le-unknown-linux-gnu s390x-unknown-linux-gnu x86_64-pc-windows-gnu; do
        rustup target add --toolchain "${RUST_VERSION}" "$target"
    done
}

install_system_deps() {
    log "Installing cross toolchains and qemu"
    sudo apt-get update -qq
    sudo apt-get install -y -qq gcc-powerpc64le-linux-gnu gcc-s390x-linux-gnu \
        gcc-mingw-w64-x86-64 qemu-user-static xz-utils
}

fetch_source() {
    log "Fetching weaver ${WEAVER_VERSION} source"
    curl -sL -o "$WORKDIR/source.tar.gz" "$SOURCE_URL"
    echo "${SOURCE_SHA256}  $WORKDIR/source.tar.gz" | sha256sum -c -
    tar xzf "$WORKDIR/source.tar.gz" -C "$WORKDIR"
    # The binary embeds the web UI via include_dir!("ui/dist"); a stub satisfies the
    # proc macro without a pnpm toolchain (registry generate/check never serve it).
    mkdir -p "$WORKDIR/weaver-${WEAVER_VERSION}/ui/dist"
    echo '<!doctype html><title>stub</title>' > "$WORKDIR/weaver-${WEAVER_VERSION}/ui/dist/index.html"
}

generate_reference() {
    log "Generating reference fixture output with the official x86_64 binary"
    curl -sL -o "$WORKDIR/reference.tar.xz" "$REFERENCE_URL"
    echo "${REFERENCE_SHA256}  $WORKDIR/reference.tar.xz" | sha256sum -c -
    tar xf "$WORKDIR/reference.tar.xz" -C "$WORKDIR"
    local weaver="$WORKDIR/weaver-x86_64-unknown-linux-musl/weaver"
    mkdir -p "$WORKDIR/reference"
    "$weaver" registry generate fixture --registry "$FIXTURE_DIR/registry" \
        --templates "$FIXTURE_DIR/templates" "$WORKDIR/reference"
}

build_target() {
    local triple="$1"
    local features="$2"
    log "Building weaver for ${triple} (features: ${features:-default})"
    (
        cd "$WORKDIR/weaver-${WEAVER_VERSION}"
        local upper
        upper="$(echo "$triple" | tr 'a-z-' 'A-Z_')"
        export "CARGO_TARGET_${upper}_LINKER=$(linker_for "$triple")"
        export "CC_${upper}=$(linker_for "$triple")"
        cargo "+${RUST_VERSION}" build --release --target "$triple" -p weaver $features
    )
}

linker_for() {
    case "$1" in
    powerpc64le-unknown-linux-gnu) echo "powerpc64le-linux-gnu-gcc" ;;
    s390x-unknown-linux-gnu) echo "s390x-linux-gnu-gcc" ;;
    x86_64-pc-windows-gnu) echo "x86_64-w64-mingw32-gcc" ;;
    *) echo "unknown cross target $1" >&2; exit 1 ;;
    esac
}

verify_and_package() {
    local triple="$1"
    local weaver="$WORKDIR/weaver-${WEAVER_VERSION}/target/${triple}/release/weaver"

    log "Verifying ${triple} output"
    local out_dir="$WORKDIR/${triple}-out"
    mkdir -p "$out_dir"
    if [[ "$triple" == *windows* ]]; then
        # Windows binaries cannot be executed from this Linux task; run the
        # verify_weaver_windows Evergreen task on a windows host after publishing.
        echo "SKIP: no runtime verification for ${triple}"
    else
        local qemu="qemu-$(echo "$triple" | cut -d- -f1)-static"
        local sysroot="/usr/$(echo "$triple" | cut -d- -f1)-linux-gnu"
        "$qemu" -L "$sysroot" "$weaver" --version
        "$qemu" -L "$sysroot" "$weaver" registry generate fixture --registry "$FIXTURE_DIR/registry" \
            --templates "$FIXTURE_DIR/templates" "$out_dir"
        for ref in "$WORKDIR"/reference/*; do
            cmp "$ref" "$out_dir/$(basename "$ref")"
        done
        echo "${triple}: fixture output is byte-identical to the official x86_64 build"
    fi

    log "Packaging ${triple}"
    local pkg_dir="$OUTDIR/${triple}"
    mkdir -p "$pkg_dir"
    cp "$weaver" "$pkg_dir/"
    (cd "$OUTDIR" && tar cJf "weaver-${triple}.tar.xz" "${triple}")
    rm -rf "$pkg_dir"
}

main() {
    install_toolchain
    install_system_deps
    fetch_source
    generate_reference
    for entry in "${TARGETS[@]}"; do
        local triple="${entry%%|*}"
        local features="${entry#*|}"
        build_target "$triple" "$features"
        verify_and_package "$triple" "$features"
    done

    log "Writing manifest"
    (
        cd "$OUTDIR"
        sha256sum *.tar.xz > SHA256SUMS
        cat SHA256SUMS
    )
    log "Done: artifacts in $OUTDIR; publish as a release and pin the sha256 values in"
    log "the mongo repository's buildscripts/bazel_rules_mongo/weaver/weaver_binary.bzl."
}

main
