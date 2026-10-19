# The HyperBEAM pin

`rebar.config` pins two things to a single HyperBEAM commit: the `hb`
dependency and the Device Forge rebar plugin (`git_subdir`). Both must name the
same commit.

That commit is not only a build dependency. The node runs HyperBEAM from this
repository's `_build`: `~/apus-v011/build-and-stage.sh` on the H100 guest
compiles this checkout, packages the device store, and the service starts with
`erl -pa .../_build/default/lib/*/ebin`. **Moving the pin is a kernel upgrade
of the public node**, not an ordinary dependency bump.

## Current pin

| Field | Value |
|---|---|
| Repository | `permaweb/HyperBEAM` |
| Commit | `1aebe74afd88f5fa35b188a16bd10aac04c4541e` |
| Branch | `cookbook/schema-vary` (tip as of 2026-09-10) |

Previously the pin was `apuslabs/HyperBEAM@28baa3d`, a merge of upstream
`cookbook/schema-vary` and upstream `edge` at `2c03978a`. That fork is archived
and must not gain new commits. The two commits produce the same code for every
path the devices exercise; the merge existed only because no upstream branch
carried both sides.

## Why this commit and not upstream `edge`

Measured on 2026-10-19, same device sources, same OTP and rebar3:

| Base | Device tests |
|---|---|
| `apuslabs/HyperBEAM@28baa3d` (previous pin) | 175/175 pass |
| `permaweb/HyperBEAM@1aebe74a` (`cookbook/schema-vary`) | 175/175 pass |
| `permaweb/HyperBEAM@2c03978a` (upstream `edge`) | 168 pass, **7 fail** |

The failures on `edge` are not cosmetic. `inference_receipt@1.0` cannot verify
its signed receipt (`hb_message:verify` returns false) and its HTTP round trip
fails with `necessary_message_not_found`. Four `inference_measurement@1.0`
tests fail on envelope shape. Devices depend on the `vary` work that
`cookbook/schema-vary` carries and `edge` does not.

`edge` has since moved to `5142ab951` (2026-09-20) and still does not contain
`cookbook/schema-vary`. No upstream branch contains both.

What `cookbook/schema-vary` lacks, compared with the old pin, is three commits
carried by `edge`: copycat weave offsets, the match-index `cache-write` hook,
and serving arbitrary LMDB 1.0 files through `hb_store_arlmdb`. The node's
`config.flat` selects none of these.

## Before changing it

1. Run `make test`. The expectation is 175/175. Any failure here is a signal
   that the new commit does not carry what the devices need.
2. Check that the new commit is on a branch that upstream will keep. A commit
   reachable only from an unmerged, unprotected topic branch can be deleted.
   Verify with `git branch -r --contains <commit>` and
   `gh pr list -R permaweb/HyperBEAM --head <branch> --state all`.
3. Change both entries in `rebar.config` and the `hb` entry in `rebar.lock`.
4. Upgrade the guest in a separate checkout. `build-and-stage.sh` refuses a
   ref whose `rebar.config` changes the pin, because it builds in the same
   directory the running node reads. Follow
   `~/apus-v011/build-and-stage.sh <name>` → staging validation on
   `:18734` → `switch-store.sh`, and keep `rollback.sh` reachable.

## History

- 2026-10-12 — pinned to the merge `28baa3d` to get `vary` plus the `edge`
  store work in one build.
- 2026-10-19 — `apuslabs/HyperBEAM` archived (HyperBEAM is a core, devices are
  extensions; APUS no longer patches it). Pin moved to the upstream branch that
  passes the device suite, so the dependency no longer points at a repository
  that will never be updated.
