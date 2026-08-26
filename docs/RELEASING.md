# Releasing Portavoz

The end-to-end recipe for cutting a public release: a notarized DMG that
updates existing users via **Sparkle** and new users via **Homebrew**. Written
from the real flow (v0.1.0 → v0.7.0, eight releases). Follow it top to bottom.

Distribution is direct-download only (no App Store) — decision D10/D20.

## 0. One-time machine setup (already done on the author's Mac)

These must exist before a release; verify them (§2) rather than re-creating:

| Requirement | What / why |
|---|---|
| **Developer ID Application cert** | in the login keychain, for codesigning |
| **Developer ID provisioning profile** | macOS Direct Distribution profile for App ID `app.portavoz.mac`, authorizing CloudKit container `iCloud.app.portavoz.mac` and Push Notifications; supplied as `PORTAVOZ_PROVISIONING_PROFILE` and embedded in the app |
| **`portavoz-notary` notarytool profile** | `xcrun notarytool store-credentials portavoz-notary` (Apple ID + app-specific password + team id) |
| **`generate_appcast`** at `~/.local/bin/generate_appcast` | from the Sparkle release; signs the appcast with the **`portavoz`** EdDSA key in the keychain (`--account portavoz`) |
| **`gh`** authenticated | `gh auth status` |

The Apple Developer portal is the source of truth for the restricted profile:
the explicit App ID must have iCloud/CloudKit and Push Notifications enabled,
the named container must be assigned to it, and the CloudKit production schema
must be deployed before publication. Create/download a **Developer ID** macOS
provisioning profile for that App ID; an App Store or development profile is
not a substitute for the direct-download artifact. Do not commit the profile.

Xcode's direct-distribution profile may represent its iCloud service grant as
the wildcard `*`. The release gate accepts that Apple-issued profile form while
still requiring the signed app itself to narrow the entitlement to exactly
`["CloudKit"]`, the production environment, and Portavoz's single container.

## 1. Pre-flight (repo must be clean & green)

```sh
git switch main && git pull --ff-only origin main
git status --short          # must be empty — clean any stray *.d / *.dia / *.swiftdeps first
swift test                  # green (DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test if "no such module")
swift test --filter StorageUpgradeTests # clean install + v0.6.0 library upgrade/reopen
make test-model-gated       # Q4/T7/D380: six model classes run in Release; full skip or FluidAudio DEBUG output fails
swiftlint --strict          # 0 violations
scripts/check-repository-hygiene.sh
```

- **CHANGELOG.md** has every user-visible change since the last release, newest first.
- Decide the **version** (SemVer): patch for fixes, minor for features. Last tag: `git tag --list 'v*' | sort -V | tail -1`.
- Stray SwiftPM artifacts (`*.d`, `*.dia`, `*.swiftdeps`) sometimes leak to the repo root from an Xcode/XCUITest build — they are **not** git-ignored, so delete them before releasing.

### Reliability identity and deterministic receipt (D147)

Choose the version and build once. The same values must stamp the deterministic
receipt, release artifact, developer build used for field evidence, and final
scorecard:

```sh
export PORTAVOZ_RELEASE_VERSION=1.0.0
export PORTAVOZ_RELEASE_BUILD="$(date +%Y%m%d%H%M)"
export PORTAVOZ_RELEASE_COMMIT="$(git rev-parse HEAD)"
export PORTAVOZ_VERSION="$PORTAVOZ_RELEASE_VERSION"
export PORTAVOZ_BUILD="$PORTAVOZ_RELEASE_BUILD"
make release-reliability-deterministic
```

This command runs hygiene, warnings-as-errors build, the complete package
suite, the isolated twenty-sample Release correction-composition budget,
strict SwiftLint, 25 recording/recovery stress iterations, the exact mixed-language
policy corpus, and seven focused XCUITest journeys in English and Spanish. It
writes `dist/release-readiness/deterministic.json` only after every command
passes. Do not reuse a receipt after the commit, version, or build changes.

The complete package step streams normally while retaining one owner-only,
ephemeral diagnostic log. If XCTest fails, the final summary contains only
deduplicated identifiers in `Module.Class/testMethod` form; assertion messages,
paths, transcripts, prompts, and generated output are not repeated. The log is
deleted after success, failure, or interruption, and the command returns the
original Swift test status. An unavailable identifier remains a red gate. Do
not replace that result with an unchanged retry, and do not use SwiftPM
`--xunit-output` as a substitute: on the current toolchain it does not contain
the package's XCTest inventory.

The ordinary Debug package suite characterizes the dense
8,000-segment/4,000-correction result without using wall time for admission.
Immediately afterward, the release owner runs twenty prebuilt
20,000-segment/400-correction permutations under `-c release`; nearest-rank
p95 must remain at or below 250 ms. This isolated command is the only
correction-composition timing authority in deterministic admission. Do not run
it concurrently with another performance gate, lower its sample count, convert
its red result into a retry, or infer combined UI/search performance from it.

D391 keeps this original deterministic receipt as one input rather than
pretending it covers all of 1.0. The final schema-2 scorecard also requires four
strict qualification receipts: complete candidate automation, reviewed source
integration/hosted CI, production-sync admission, and physical VoiceOver/Voice
Control on Sequoia and Tahoe. A missing receipt is a normal release-blocking
state; do not hand-author or copy one from a neighboring commit. Pass each
receipt explicitly to the evaluator only after its owning gate or field
workflow has produced it.

### Reviewed source-integration receipt (D402)

This receipt cannot be produced from a local branch. First obtain explicit
authorization for the push/PR/merge, integrate the exact candidate through one
non-draft pull request to `main`, obtain at least one independent current human
approval of the final PR head, resolve every change request, and let the `CI`
push workflow pass on the resulting merge commit without rerunning it. A
squash or merge changes the source identity: rerun candidate automation for
that integrated commit before final admission.

While that integrated commit is still the exact current `main` head, explicitly
dispatch the read-only evidence owner from `main` in GitHub Actions with the
same release identity. The workflow checks out trusted `main`; it refuses a
side-branch dispatch, a stale ancestor, or any mismatch among the dispatch
source, checked-out HEAD, `GITHUB_SHA`, requested commit, and GitHub's current
`main` head. It only queries GitHub and uploads an artifact; it cannot push,
merge, release, or mark caller-supplied proofs pass.

```sh
gh workflow run source-integration-evidence.yml \
  -f version="$PORTAVOZ_RELEASE_VERSION" \
  -f build="$PORTAVOZ_RELEASE_BUILD" \
  -f commit="$PORTAVOZ_RELEASE_COMMIT"
```

Download the completed run's uniquely named artifact and pass its
`qualification.json` to the scorecard **without separating it from** sibling
`authority.json`. The receipt carries the authority's canonical SHA-256 and the
scorecard rejects a renamed, copied-alone, missing, or drifted pair.
Bot/self/outsider/stale/dismissed approvals, a commit outside
or behind current `main`, multiple unchanged-commit CI runs, any rerun, a
missing/failing job, or workflow metadata drift produces no receipt. Do not
weaken this by editing JSON or dispatching again for the same unchanged commit.

### Candidate-automation receipt (D392/D393)

Run this only from the clean commit intended to become the candidate. It is a
long sequential gate by design: benchmark, model, resource, and UI processes
must not contend with one another. The runner reuses one XCUITest build across
English and Spanish and accepts no caller-supplied proof state.

```sh
make candidate-automation \
  PORTAVOZ_RELEASE_VERSION="$PORTAVOZ_RELEASE_VERSION" \
  PORTAVOZ_RELEASE_BUILD="$PORTAVOZ_RELEASE_BUILD"
```

The new private output directory under `dist/release-readiness/` contains the
deterministic receipt and specialized content-free artifacts. It contains
`qualification.json` only if all eight gates pass against the same full Git
commit. Do not copy that file to a new commit or edit it by hand.

The installed-model lane generates its own short spoken fixture plus four long
alternating Daniel/Paulina EN/ES turns from tracked public text. Each turn uses
an explicit voice process; the runner never treats embedded voice markup as
audio identity. It validates every mono PCM segment, joins them with exact
700 ms gaps into an owner-only 16 kHz WAV of at least 60 seconds, uses already
installed assets without downloading, withholds raw model output, and removes
all final and intermediate scratch audio afterward. Exported private
`PORTAVOZ_TEST_WAV`, conversation, real-UI-audio, waveform, or signing
variables are deliberately not inherited into candidate proof; routine
qualification never needs one of your meetings.

The performance subgate requires authoritative measurements for all twelve
automated scale/semantic/Spotlight metrics. It also requires the other thirteen
declared waveform, Instruments, and manual/real-data metrics to remain exactly
and visibly `not-measured`; this receipt does not certify those lanes. The
resource subgate selects only this Mac's accepted profile and requires three
Release samples for all nine scenarios. Additional hosts, Sequoia/Tahoe,
VoiceOver/Voice Control, signed distribution, production CloudKit, hosted CI,
and field evidence still follow their separate procedures below.

### Performance gate (PERF-001/PERF-008)

```sh
make perf-ledger            # scorecard in dist/perf-ledger/ledger.md; non-zero on a budget miss
```

Run it on the **named stable Mac**, not on a laptop under load and not in
hosted CI: the scorecard prints `authoritative` only when every report comes
from one release build on one Apple Silicon machine that matches the committed
baseline, and `informational` otherwise. Treat an informational scorecard as
unmeasured.

- **Exit 0** — every measured journey is inside its budget.
- **Exit 2** — regression candidates. PERF-008 wants three stable runs before
  one counts, so re-run; if it repeats, it is real.
- **Exit 1** — a journey missed its absolute budget, or a declared checkpoint
  was missing from a report. Do not release.

**Verdict withheld — unstable samples** means the metric missed its budget
while its own iterations disagreed with each other: the machine was busy, so
the number convicts nobody. Close what is competing for the CPU and measure
again; that section is the ledger refusing to guess, not a bug.

A **Comparability** line means the baseline was built with a different Swift
toolchain, or predates toolchain recording. It does not invalidate the run; it
says a delta may be codegen rather than product code, so weigh it before
blaming a commit.

The scorecard also lists the journeys this run did **not** measure — cold
start, recording memory, live lag, drift, DER, refine, summary. They need a
microphone, a real recording, or Instruments, so they stay hand-run; their
commands are in the `source` field of each metric in
`docs/evidence/perf-thresholds.json`. Reading "not measured" as "fine" is the
one mistake this ledger exists to prevent.

To move a baseline forward after an accepted improvement, copy the new report
into `docs/evidence/` and point the `baselines` map in
`docs/evidence/perf-thresholds.json` at it — a reviewable commit, never a
silent overwrite.

## 2. Verify the release prerequisites

```sh
# Signing identity — MUST resolve to the SHA-1 hash, see the gotcha below.
security find-identity -v -p codesigning | grep 8C8B5B1453BB7E3CC48D78FE2D4A47AC6EBB9D17
# Notary profile works:
xcrun notarytool history --keychain-profile portavoz-notary | head -3
# Appcast signer present:
ls -l ~/.local/bin/generate_appcast
# Restricted-capability profile exists and decodes:
export PORTAVOZ_PROVISIONING_PROFILE="/absolute/path/to/Portavoz.provisionprofile"
test -f "$PORTAVOZ_PROVISIONING_PROFILE"
security cms -D -i "$PORTAVOZ_PROVISIONING_PROFILE" >/dev/null
```

> **GOTCHA — two duplicate Developer ID identities.** The keychain holds two
> certs both named `Developer ID Application: Johnny IV Young (JGWX5ZT2N2)`, so
> passing the **name** makes `codesign` fail with *"ambiguous"*. Always pass the
> **SHA-1 hash** `8C8B5B1453BB7E3CC48D78FE2D4A47AC6EBB9D17` as
> `PORTAVOZ_SIGN_IDENTITY`.

## 3. Build + notarize (local — nothing is public yet)

```sh
export PORTAVOZ_SIGN_IDENTITY="8C8B5B1453BB7E3CC48D78FE2D4A47AC6EBB9D17"
export PORTAVOZ_NOTARY_PROFILE="portavoz-notary"
export PORTAVOZ_PROVISIONING_PROFILE="/absolute/path/to/Portavoz.provisionprofile"
scripts/make-release.sh "$PORTAVOZ_RELEASE_VERSION"
```

`scripts/make-release.sh` (see its header) does, in order:
1. `make-app.sh --release --version <v> --build <YYYYMMDDHHMM>` — requires the exported release commit to match a clean `HEAD` before and after the app build, stamps it as `PortavozSourceCommit`, version-stamps, embeds the supplied Developer ID profile, signs the `.app` with the exact production CloudKit/APNs entitlements, and rejects a missing, expired, or mismatched profile.
2. `make-dmg.sh --skip-build` — archives and notarizes the signed app, staples
   and verifies it, packages that app into the DMG, then independently
   notarizes/staples the DMG. It mounts the result and verifies a copied-out
   app exactly as Homebrew will consume it.
3. Generates the **EdDSA-signed `appcast.xml`** (`generate_appcast --account portavoz`).
4. Renders the Homebrew **cask** with the real version + sha256.

Output lands in **`dist/release/`**: `Portavoz-<version>.dmg`, `appcast.xml`, `portavoz.rb`.

It takes several minutes (the Swift release build + Apple notarization). Run it
in the background and wait for `Release <version> ready in dist/release/`.

### Verify the artifacts before publishing

```sh
scripts/verify-distribution.sh \
  "dist/release/Portavoz-$PORTAVOZ_RELEASE_VERSION.dmg" \
  --receipt dist/release-readiness/distribution.json
grep -E 'sparkle:version|edSignature' dist/release/appcast.xml # version + signature present
grep -E 'version |sha256 ' dist/release/portavoz.rb            # match the DMG
```

The distribution verifier is intentionally stricter than opening the DMG. A
stapled outer image can open while a cask-extracted app has no embedded ticket
and must reach Apple's service at first launch. Never publish unless both
boundaries pass. It also decodes the app copied from the DMG and requires its
signed container/service/production/push values to match the unexpired embedded
profile exactly. The verifier requires the sealed Info.plist identity to remain
`app.portavoz.mac` and the profile's application-identifier entitlement to
equal one of its declared application-identifier prefixes, a delimiter, and
that exact bundle ID. Manual signing materializes the native macOS App ID and
developer-team entitlements from the decoded profile; the final signature must
match both. Matching legacy and namespaced profile application-identifier keys
are accepted; conflicting aliases fail closed. Distribution verification then
reads the embedded `PortavozSourceCommit` and requires that commit to match
`PORTAVOZ_RELEASE_COMMIT` before writing the receipt. This catches a restricted-
capability app that notarizes but would fail at launch, never reach the intended
container, carry a profile for another App ID, or be attributed to adjacent
source.

### Local-only development versus exact-ID sync qualification (D403)

`make app`, `make install`, and XCUITest intentionally use
`packaging/portavoz-local.entitlements` when no profile is supplied. They stay
fully local and the Sync pane reports that the build is not provisioned.
`make install` changes the bundle identifier to `app.portavoz.mac.dev`, so it
now rejects `PORTAVOZ_PROVISIONING_PROFILE`: a profile for the production App ID
cannot authorize that development identity.

After the exact integrated candidate exists, build the separate production-
sync qualification artifact with the same fixed release identity:

```sh
export PORTAVOZ_RELEASE_VERSION="1.0.0"
export PORTAVOZ_RELEASE_BUILD="<the fixed release build>"
export PORTAVOZ_RELEASE_COMMIT="$(git rev-parse HEAD)"
export PORTAVOZ_PROVISIONING_PROFILE="/absolute/path/to/Portavoz.provisionprofile"
export PORTAVOZ_SIGN_IDENTITY="8C8B5B1453BB7E3CC48D78FE2D4A47AC6EBB9D17"
make production-sync-qualification-app
scripts/verify-cloudkit-capabilities.sh \
  "dist/Portavoz Sync Qualification.app"
```

The builder requires a clean exact checkout, real signing identity, matching
profile, numeric build, and full source commit. It changes only the display
name, re-signs the outer app with the profile-derived App ID and Team ID, then
re-verifies signature, profile, production
capabilities, version, build, and source stamp. The bundle deliberately remains
under `dist/`. Do **not** copy it into `/Applications`, register it with
LaunchServices, or open it beside the user's notarized `Portavoz.app`; the
production-sync evidence owner executes its binary directly with isolated
scratch state. Building this artifact alone creates no CloudKit receipt and
does not close the two-Mac matrix.

### Run the staged production-sync qualification (D404)

This is an authorized physical gate, not routine local QA. Use two clean Macs,
assign one role to Sequoia and the other to Tahoe or newer,
the same exact source commit and unchanged qualification app, production
CloudKit/APNs access, the original iCloud account on both roles, and a second
real iCloud account for role A's switch stages. Never point it at a Portavoz
library: the owner creates its fixed public EN/ES meeting under role-local
scratch storage.

On role A, initialize one empty mode-0700 workspace:

```sh
export PORTAVOZ_PRODUCTION_SYNC_WORKSPACE="$HOME/PortavozQualification/portavoz-sync-run"
make production-sync-qualification-init \
  PORTAVOZ_RELEASE_VERSION="$PORTAVOZ_RELEASE_VERSION" \
  PORTAVOZ_RELEASE_BUILD="$PORTAVOZ_RELEASE_BUILD" \
  PORTAVOZ_RELEASE_COMMIT="$PORTAVOZ_RELEASE_COMMIT"
```

The run manifest binds the main executable, outer code-resource seal, embedded
production provisioning profile, and contract digests. Copy the unchanged
`.app` and only the mode-0600 `run.json` to role B's empty
mode-0700 local workspace. Each Mac must retain its own `roles/` and `app-shell/`
directories; never copy or merge those databases. Before a cross-role stage,
copy only the required owner-written receipt named by the tracked contract into
the identical `receipts/<role>/` relative path on the other Mac, preserving
mode 0600. Then run one stage at a time:

```sh
make production-sync-qualification-stage \
  PORTAVOZ_PRODUCTION_SYNC_WORKSPACE="$PORTAVOZ_PRODUCTION_SYNC_WORKSPACE" \
  PORTAVOZ_PRODUCTION_SYNC_ROLE=a \
  PORTAVOZ_PRODUCTION_SYNC_STAGE=prepare-existing

make production-sync-qualification-status \
  PORTAVOZ_PRODUCTION_SYNC_WORKSPACE="$PORTAVOZ_PRODUCTION_SYNC_WORKSPACE"
```

Follow all 27 stages in
`docs/evidence/production-sync-qualification.json`. The owner rejects a stage
until every declared prerequisite receipt is present and valid. For the one
concurrent boundary, start role B's `await-push` after `b.receive-retry` and
leave it running. Wait until it writes `live/b-await-push.json` and prints
`production-sync await-push READY`. Copy that mode-0600 marker to the identical
relative path in role A's workspace, then run role A's `push-source` without
terminating B; do not manually refresh role B. The A receipt must consume that
marker, and a qualifying B receipt must bind the same process/host marker, a
real remote-notification wake, and the exact pushed corpus.

Six stages declare an irreducible `externalAction`. Perform it immediately
before the stage and pass that exact token as an acknowledgment; the app still
has to observe the resulting CloudKit state, so this token is never proof:

| Stage | Required physical action | Exact value |
|---|---|---|
| `a.offline-attempt` | Disable networking on role A | `disable-network` |
| `a.retry-relaunch` | Restore networking on role A | `restore-network` |
| `a.observe-signout` | Sign role A out of the original iCloud account | `sign-out-original-account` |
| `a.resume-signin` | Sign role A back into the original iCloud account | `sign-in-original-account` |
| `a.observe-account-switch` | Switch role A to the real secondary iCloud account | `switch-to-secondary-account` |
| `a.observe-account-restore` | Restore role A to the original iCloud account | `restore-original-account` |

For example:

```sh
make production-sync-qualification-stage \
  PORTAVOZ_PRODUCTION_SYNC_WORKSPACE="$PORTAVOZ_PRODUCTION_SYNC_WORKSPACE" \
  PORTAVOZ_PRODUCTION_SYNC_ROLE=a \
  PORTAVOZ_PRODUCTION_SYNC_STAGE=offline-attempt \
  PORTAVOZ_PRODUCTION_SYNC_EXTERNAL_ACTION=disable-network
```

Do not pass the variable for stages whose contract value is `none`. A missing,
wrong, or surplus acknowledgment fails before app launch.

The stage workspace must be a strict descendant of the current user's home or
the system temporary directory; do not use either root itself or an external
volume. After both local workspaces are complete, assemble a new mode-0700
evidence directory containing only the identical `run.json`,
`live/b-await-push.json`, and all 27 receipts. Do not include role databases.
From the exact clean source commit, finalize into a new output:

```sh
make production-sync-qualification-finalize \
  PORTAVOZ_PRODUCTION_SYNC_WORKSPACE="/absolute/evidence/complete-sync-run" \
  PORTAVOZ_PRODUCTION_SYNC_OUTPUT="/absolute/evidence/production-sync-authority"
```

Only the finalizer writes `authority.json` and the generic
`qualification.json`; the latter binds the canonical authority digest and the
scorecard requires the intact sibling pair. It rejects an incomplete or extra
set, broken chains, reused app processes, one physical Mac acting as both
roles, account/OS drift,
a fake account switch, zero-wake push, malformed or content-bearing receipts,
and non-owner permissions. A green unit, packaging, or XCUITest run does not
substitute for this two-Mac/account/APNs evidence.

The release and field-test profile has an expiration date and macOS evaluates
it at launch. Refresh and re-embed it before expiry; never work around a profile
failure by signing the restricted entitlements without one.

### Run the physical assistive-technology qualification (D405)

Follow [`ASSISTIVE-VALIDATION.md`](ASSISTIVE-VALIDATION.md) after candidate
automation has passed for the exact source and the unchanged Developer-ID-
signed `app.portavoz.mac.dev` bundle is available. The owner runs the public
disposable seed in English and Spanish through VoiceOver and Voice Control on
physical Sequoia and Tahoe-or-newer Apple-silicon Macs. It binds every ordered
human observation to the candidate, app seals, assistive technology, app
process, run-scoped host, and exact macOS build.

VoiceOver requires both the human acknowledgment and the documented
`NSWorkspace.isVoiceOverEnabled` observation. Voice Control deliberately uses
human authority only because this project has no documented public active-
state API for it. A failed checkpoint is immutable and requires a new run; it
cannot be overwritten or retried into the same green cell. Finalization writes
one new `authority.json` plus `qualification.json` pair only after all four
physical cells have complete EN/ES chains. Host-scope inequality is not
physical-hardware attestation, and deterministic XCUITest does not replace the
human VoiceOver/Voice Control observation.

### Assemble the fail-closed reliability scorecard

Install the candidate-stamped developer build and collect the protocol-2
packages in [`FIELD-VALIDATION.md`](FIELD-VALIDATION.md). The release contract
requires built-in speaker/mic and AirPods on both macOS 15 and macOS 26, plus
callback-recovery, long-call, model-cold-start, and mixed-language packages.
Every package must report the exact release version and build above.

```sh
make release-reliability \
  PORTAVOZ_RELEASE_VERSION="$PORTAVOZ_RELEASE_VERSION" \
  PORTAVOZ_RELEASE_BUILD="$PORTAVOZ_RELEASE_BUILD" \
  PORTAVOZ_RELEASE_COMMIT="$PORTAVOZ_RELEASE_COMMIT" \
  PORTAVOZ_QUALIFICATION_RECEIPT_ARGS='\
    --qualification-receipt /path/to/candidate-automation.json
    --qualification-receipt /path/to/source-integration/qualification.json
    --qualification-receipt /path/to/production-sync-authority/qualification.json
    --qualification-receipt /path/to/assistive-technology-authority/qualification.json' \
  PORTAVOZ_FIELD_EVIDENCE_ARGS='
    --field-evidence /path/to/built-in-sequoia
    --field-evidence /path/to/built-in-tahoe
    --field-evidence /path/to/airpods-sequoia
    --field-evidence /path/to/airpods-tahoe
    --field-evidence /path/to/callback-recovery
    --field-evidence /path/to/long-call
    --field-evidence /path/to/model-cold-start
    --field-evidence /path/to/mixed-language'
```

Review `dist/release-readiness/scorecard/readiness.md`. It must contain all 29
schema-2 cells, name the exact artifact digest, and say **PASS**.
Missing, failed, incomplete, not-observed, stale-version, stale-build, and
stale-commit evidence blocks publication. The scorecard is content-free and
owner-only; it is ignored release evidence, not a tracked substitute for
`docs/GAPS.md`.

## 4. Publish (outward-facing — get an explicit OK first)

**The author prefers to review the built DMG + notes and give an explicit "OK"
before this step.** Stop after §3, show the artifacts, then run §4 on approval.

```sh
git push origin main                                   # if main has unpushed commits
git tag v<version> && git push origin v<version>

gh release create v<version> \
  dist/release/Portavoz-<version>.dmg \
  dist/release/appcast.xml \
  --title "Portavoz <version> — <catchy phrase>" \
  --notes-file <release-notes.md>

gh workflow run update-cask.yml -f tag=v<version>      # bumps johnny4young/homebrew-tap
```

- **Attach BOTH** the DMG and `appcast.xml` — Sparkle fetches the appcast from
  `releases/latest/download/appcast.xml`, and the cask/appcast link to
  `releases/download/v<version>/Portavoz-<version>.dmg`.
- **Release notes**: compile from the CHANGELOG entries added since the previous
  tag (`git log v<prev>..HEAD`). A "Highlights" list, then "Also in this
  release", ending with *"runs 100% on your Mac. Update from within Portavoz, or
  `brew upgrade --cask portavoz`."*

### Title format — keep it consistent

`Portavoz <version> — <lowercase, catchy phrase>`. The dash is an em dash (`—`).

| Tag | Title |
|---|---|
| v0.5.1 | Portavoz 0.5.1 — custom structures, and the call on AirPods |
| v0.5.0 | Portavoz 0.5.0 — a new look, and a mirror |
| v0.4.0 | Portavoz 0.4.0 — safety nets and sharper gestures |
| v0.3.0 | Portavoz 0.3.0 — your meetings, portable |
| v0.2.0 | Portavoz 0.2.0 — lives on your Mac, not just in its window |
| v0.1.0 | Portavoz 0.1.0 — knows who said what, locally |

## 5. Verify it's live

```sh
gh release view v<version> --json assets -q '[.assets[].name] | join(", ")'   # appcast.xml, Portavoz-<version>.dmg
gh run watch <cask-run-id> --exit-status                                        # update-cask workflow succeeds
curl -s https://raw.githubusercontent.com/johnny4young/homebrew-tap/main/Casks/portavoz.rb | grep -E 'version |sha256 '
curl -sIL https://github.com/johnny4young/portavoz/releases/download/v<version>/Portavoz-<version>.dmg | grep -i '^HTTP'  # 200
```

Existing users now see Sparkle's "Update available"; Homebrew users can
`brew upgrade --cask portavoz`.

### Reproduce the Homebrew extraction boundary

After the cask workflow is live, install to a disposable app directory instead
of replacing the maintainer's release app:

```sh
APPDIR="$(mktemp -d)"
brew install --cask --appdir="$APPDIR" johnny4young/tap/portavoz
codesign --verify --deep --strict --verbose=2 "$APPDIR/Portavoz.app"
xcrun stapler validate "$APPDIR/Portavoz.app"
spctl -a -vvv -t exec "$APPDIR/Portavoz.app"
brew uninstall --cask --force portavoz
```

The release criterion is one additional clean-machine launch on macOS 15
Sequoia with no previous Portavoz app or Homebrew receipt. If it fails, preserve
the exact output from
`brew install --verbose --debug --cask johnny4young/tap/portavoz`; do not infer
a packaging cause from a paraphrased alert.

## Undo a bad release

```sh
gh release delete v<version> --yes
git push --delete origin v<version>
git tag -d v<version>
```
Then fix and re-run from §3. (The cask bump is a separate commit in the tap repo;
revert it there if it already landed.)

## Hard rules

- **NEVER touch `/Applications/Portavoz.app`** — the author's notarized release
  copy; it updates only via Sparkle/Homebrew. The dev app is
  `/Applications/Portavoz Dev.app` (`make install`).
- No AI co-authorship trailers in the tag, release, or commit messages.
