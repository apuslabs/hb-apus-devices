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
| Commit | `80a72735230882643f1ca9afe4e18af57ac065db` |
| Tag | `v0.11` (merge of `lead/v0.11-security-work` into `release/v0.11`) |

The six device suites pass against it (187/187, 2026-11-18). The public node
still runs the previous pin, `1aebe74a` on `cookbook/schema-vary`, until the
guest is upgraded (see "Before changing it" and "Moving to v0.11").

Before `1aebe74a` the pin was `apuslabs/HyperBEAM@28baa3d`, a merge of upstream
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

## Moving to v0.11

Measured on 2026-11-18 with fresh dependencies (`rebar.lock` regenerated;
check `git -C _build/default/lib/hb rev-parse HEAD`, a stale lock silently
tests the old pin): before the device changes 154 of 175 tests passed. Three
kernel changes needed device changes; the suites passed 178/178, with three
added tests: the runtime host admission, the `http_request` relay, and the
resolver's HashPath of the captured receipt fixture. Legacy receipt
verification and the JSON `verify-hashpath` reply bring them to 187/187.

- **Host policy.** `hb_hostname` vets every host `relay@1.0` reaches,
  including a `peer` the call gives, against `hosts-allowed` and
  `hosts-block-internal` (default `true`). The pre-v0.11 names
  `relay-block-internal` and `relay-allowed-hosts` are no longer read.
  `inference@1.0` admits only the `inference-peer` host, for its runtime
  calls only; the node's policy is unchanged for every other relay call.
  `relay@1.0` reads the relayed message from `relay-subject` (it was
  `target`): `inference@1.0` and the `agent@1.0` `http_request` tool now use
  that key.
- **Committers.** `hb_message:signers/2` and commitment `committer` values are
  committer URIs (`uri-did-ar-…` for an Arweave key, see `hb_committer`),
  once per committer. Receipts and observation verification still publish
  Arweave addresses (`hb_util:committer_address/1`); `receipt-publishers`
  accepts addresses or URIs. Request options no longer carry the node's
  `priv-wallet`; the receipt device reads the node address with
  `hb_opts:address/1`.
- **HashPaths.** AO-Core records `hb_hashpath` claims such as
  `ao:~inference@1.0/ao:<request ID>.<result ID>`, and message IDs differ
  from the previous kernel's for the same message. `inference@1.0` exposes
  the step `ao:~inference@1.0/ao:<request ID>`; `verify-hashpath` and
  `verification-status` accept the recomputed claim or the step. HashPaths
  recorded by a node on the previous kernel (`<base ID>/<request ID>`) do
  not recompute with v0.11's functions, so `inference_receipt@1.0` carries
  a port of that kernel's `hb_path:hashpath/3` and `httpsig@1.0` HMAC IDs
  and verifies them with it; `verify-hashpath` names the algorithm it used
  in `hashpath-algorithm` (`legacy-sha-256-chain` or `hb-hashpath-v0.11`).
- **Replies.** The node no longer adds `status` to a result message, so a
  JSON reply has no top-level `status` key. Text values of a result message
  that start with `ao:` are read as links when the reply is encoded, so
  `verify-hashpath`, whose results carry HashPaths, answers with a JSON
  body.

## Before changing it

1. Run `make test`. The expectation is 187/187. Any failure here is a signal
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
- 2026-11-18 — branch `test/hb-v0.11` moves the pin to upstream tag `v0.11`
  (`80a7273`) with the device changes above. Not yet on the public node.
- 2026-10-19 — `apuslabs/HyperBEAM` archived (HyperBEAM is a core, devices are
  extensions; APUS no longer patches it). Pin moved to the upstream branch that
  passes the device suite, so the dependency no longer points at a repository
  that will never be updated.
