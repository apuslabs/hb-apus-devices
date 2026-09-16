# PermawebOS measurement sources

Source: https://github.com/permaweb/os

Pinned revision: `63f88cc3a73af0e5af13b58887b2870d8b486c48`

The Erlang and Rust files in this directory are unchanged upstream sources.
They provide `measurement@1.0`, `system@1.0`, and the `snp@1.0` measurement
backend. Apus composes them through their public device interfaces.

Run `make setup-measurement` on the target architecture before packaging.
It builds the upstream SNP NIF and places its static Erlang wrapper and shared
library in the SNP device's Forge archive. Generated binaries are not tracked.
