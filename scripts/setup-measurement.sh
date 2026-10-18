#!/usr/bin/env bash
# Build the SNP NIF of the vendored PermawebOS snp@1.0 device and place its
# Erlang wrapper and shared library where Device Forge packages them.
# Run on the Linux target host before packaging; requires cargo and erlc.
set -euo pipefail
cd "$(dirname "$0")/.."
measurement_root="$PWD/vendor/permaweb-os"
measurement_priv="$measurement_root/src/priv/dev_lapee_snp"
cargo build --release --locked --manifest-path "$measurement_root/native/lapee_snp_nif/Cargo.toml"
mkdir -p "$measurement_priv/crates/lapee_snp_nif"
erlc -o "$measurement_priv" "$measurement_root/native/lapee_snp_nif.erl"
cp "$measurement_root/native/lapee_snp_nif/target/release/liblapee_snp_nif.so" \
    "$measurement_priv/crates/lapee_snp_nif/lapee_snp_nif.so"
