# Physical assistive-technology validation

This runbook produces the bounded `assistive-technology` release authority for
Portavoz 1.0.0. It exercises one unchanged Developer-ID-signed **Portavoz Dev**
candidate with VoiceOver and Voice Control on physical Apple-silicon Macs. It
uses only the public bilingual demo corpus and disposable storage; it never
opens the user's library or `/Applications/Portavoz.app`.

The producer is intentionally finite. It requires these four cells:

| Cell | Host family | Locales |
|---|---|---|
| `voiceover-sequoia` | macOS 15 only | English, then Spanish |
| `voiceover-tahoe` | macOS 26 or newer | English, then Spanish |
| `voice-control-sequoia` | macOS 15 only | English, then Spanish |
| `voice-control-tahoe` | macOS 26 or newer | English, then Spanish |

VoiceOver and Voice Control must run on the same host and exact macOS build
within each OS family. The Sequoia and Tahoe families must expose different
run-scoped host values. Those values are salted hashes of `IOPlatformUUID`;
they do **not** cryptographically attest physical hardware. The trusted
operator and retained release record remain part of the authority.

## What this proves

- The exact signed candidate can complete the fixed public-seed journey with
  VoiceOver and Voice Control, in English and Spanish, on the stated hosts.
- Every observation is ordered, content-free, immutable, digest-chained, and
  bound to the candidate receipt, source commit, app seals, signing-team scope,
  host scope, macOS build, assistive technology, locale, and app process.
- A failed checkpoint is retained, the exact owned Dev process is asked to
  terminate, and the cell cannot be turned green. Start a new run instead.
- Final publication creates one new owner-only directory containing the
  inseparable `authority.json` and `qualification.json` pair.

It does not prove notarization, distribution, CloudKit, an external account,
real audio hardware, long meetings, field quality, or future macOS behavior.
XCUITest remains the deterministic regression oracle; this protocol adds the
irreducible human interaction observation and does not replace full bilingual
release automation.

## Authority and privacy boundary

Use only a trusted human operator who can tell whether every action and state
was reached through the named assistive technology. Do not use the mouse,
trackpad, Switch Control, automation, or a second assistive technology to
rescue a checkpoint. Ordinary typing is allowed where the journey requires
public fixture text.

The evidence contains no name, transcript, note, question, answer, URL,
screenshot, screen recording, audio, path, or raw log. Do not add any of those
to the evidence tree. The disposable app log exists only while a locale is
active and is deleted on a successful finish or a recorded failure whose exact
process exits. If graceful cleanup cannot confirm exit, scratch state remains
for diagnosis and the run is failed.

VoiceOver activation has two authorities: the human confirmation and Apple's
documented `NSWorkspace.isVoiceOverEnabled` state. Voice Control has no public
equivalent used by this project, so its activation is deliberately
human-observed only. Do not reinterpret `systemObserved: null` as missing
evidence.

Apple's operating references are:

- [Get started with VoiceOver on Mac](https://support.apple.com/guide/voiceover/get-started-with-voiceover-vo4be8816d70/mac)
- [Use Voice Control on Mac](https://support.apple.com/en-gb/guide/mac-help/mh40719/mac)
- [`NSWorkspace.isVoiceOverEnabled`](https://developer.apple.com/documentation/appkit/nsworkspace/isvoiceoverenabled)
- [Perform accessibility testing for your app](https://developer.apple.com/documentation/accessibility/performing-accessibility-testing-for-your-app)

## Prerequisites

1. Finish candidate automation for the exact version, numeric build, and full
   40-character source commit. Its receipt must be mode `0600` and every proof
   must be `pass`.
2. Build and deep-verify the unchanged Developer-ID-signed
   `app.portavoz.mac.dev` candidate. Its display name and bundle name must both
   be `Portavoz Dev`; the source stamp, version, and build must match the
   receipt. Never substitute or inspect `/Applications/Portavoz.app`.
3. Check out that exact commit, with no tracked or untracked files, on every
   participating Mac. The Python owner and this repository must remain
   unchanged throughout collection and finalization.
4. Use physical Apple-silicon Macs: one exact macOS 15 build and one exact
   macOS 26-or-newer build. Record which trusted operator owns each host in the
   private release log, not in the machine-readable evidence.
5. Copy the exact app bundle without re-signing it. Re-run
   `codesign --verify --deep --strict --verbose=2` after every copy.
6. Keep every evidence root and transfer directory mode `0700`; keep every JSON
   file mode `0600`. Use a local APFS path below the operator's home directory
   or a private temporary directory.

## Initialize the one candidate-bound run

Set absolute paths. The app may be `/Applications/Portavoz Dev.app`; it must
never be the stable app.

```sh
export PORTAVOZ_RELEASE_VERSION=1.0.0
export PORTAVOZ_RELEASE_BUILD=YOUR_NUMERIC_BUILD
export PORTAVOZ_RELEASE_COMMIT=YOUR_FULL_COMMIT
export PORTAVOZ_ASSISTIVE_APP='/Applications/Portavoz Dev.app'
export PORTAVOZ_ASSISTIVE_CANDIDATE_RECEIPT='/private/path/candidate-automation.json'
export PORTAVOZ_ASSISTIVE_EVIDENCE_ROOT='/private/path/assistive-run'

make assistive-qualification-init
make assistive-qualification-status
```

Initialization records no physical pass. Copy only the unchanged `run.json`
and exact app to each physical host. Create the host evidence root as mode
`0700`, copy `run.json` as mode `0600`, and retain identical bytes. Do not copy
another host's `cells/` directory onto a collection host.

## Run one locale

Use `voiceover` or `voice-control` and `en` or `es`. The confirmation must be
typed separately and exactly match the active technology.

```sh
export PORTAVOZ_ASSISTIVE_TECHNOLOGY=voiceover
export PORTAVOZ_ASSISTIVE_LOCALE=en
export PORTAVOZ_ASSISTIVE_CONFIRM_TECHNOLOGY=voiceover
make assistive-qualification-start
```

The owner starts the exact executable directly with `-use-temp-store`, the
public demo and Skills seeds, the synthetic Interview Assist runtime, isolated
database/audio/defaults paths, and a fixed locale. It rejects inherited
Portavoz/XCTest overrides, another running copy of the exact candidate, a
stale runtime, a missing seed-ready marker, host/build drift, or technology
drift. It never reads the production library.

For VoiceOver, turn it on and confirm the tutorial is dismissed before start.
Use Control-Option navigation and VO-Space activation; Command-Tab may bring
Portavoz Dev forward. For Voice Control, wait until Voice Control is listening,
then use commands such as “Show names,” “Show numbers,” “Click *name*,” “Press
Escape,” and “Press Space.” The spoken command vocabulary may localize with
macOS; the observable Portavoz outcome below does not.

## Fixed checkpoints

Complete checkpoints in order. A checkpoint passes only if all named actions,
focus transitions, content, and recovery states are independently perceivable
and operable through the selected technology. If any step is ambiguous,
unreachable, incorrectly named, loses focus, crashes, or requires a pointer,
record `fail`.

1. **`library-navigation`**
   - Reach New recording, Import audio, Ask, Insights, and Commitment radar.
   - Find the public `Test meeting` under Earlier/Antes.
   - Search for `viernes`, open the identified result, and verify the player
     reaches `0:03`.
2. **`meeting-evidence-navigation`**
   - In `Test meeting`, reach My notes/Mis notas and the raw public note
     `revisar budget Q3`; verify the Enhance control is separately named.
   - Activate the first Overview source. Verify the cited transcript row gains
     the selected/focused state and the player reaches `0:03`.
3. **`ask-citation-navigation`**
   - Open Ask and choose Notes. Ask `budget Q3`; verify the public raw-note
     citation names the meeting, author, and `0:12` before the deterministic
     disposable answer finishes.
   - Choose Meeting, select `Test meeting`, ask `viernes`, and verify progressive
     evidence, the cited answer, and citation navigation back to `0:03`.
   - Do not enable Web for this physical checkpoint; deterministic Web
     consent, freshness, hostile content, and injection cases remain owned by
     the local fixture and XCUITest lanes.
4. **`skills-review-and-focus`**
   - From the seeded meeting, verify repeated proposals for the same Skill have
     distinct accessible action names.
   - Open Settings > Skills, open the seeded Waiting receipt, close it with
     Escape, and activate Space/“Press Space.” The exact receipt must regain
     focus and reopen; its descriptions must remain distinct.
5. **`interview-assist-navigation`**
   - Start New recording and enable Interview Assist.
   - Verify the current public synthetic question. Add the public objective
     `Evaluate incident-response judgment` in English or
     `Evaluar criterio de respuesta a incidentes` in Spanish.
   - Request the answer and reach its exact cited evidence. No installed model,
     microphone, or private interview is used.
6. **`recording-stop-recovery`**
   - Reach and activate the visible Stop control for that synthetic recording.
   - Verify Stop completes, the disposable meeting remains reachable, and the
     app remains responsive with no crash, stranded modal, or lost navigation
     context.

Record each result immediately. For example:

```sh
export PORTAVOZ_ASSISTIVE_CHECKPOINT=library-navigation
export PORTAVOZ_ASSISTIVE_OUTCOME=pass
export PORTAVOZ_ASSISTIVE_CONFIRM_OBSERVATION=library-navigation:pass
make assistive-qualification-observe
```

Repeat with the next identifier printed by the owner. Never pre-create, edit,
rename, or replace a receipt. After all six pass:

```sh
make assistive-qualification-finish
```

Run English then Spanish for the same technology. Then run the other
technology on that same host and exact macOS build. If any checkpoint fails,
retain the failed run, do not call `finish`, and initialize a wholly new run
for another attempt. A process-cleanup error is also a failed run; quit only
the exact Portavoz Dev copy if it remains visible.

## Assemble and finalize

Bring the two completed cell directories from the Sequoia host and the two
from the Tahoe host back under the original run's `cells/` directory, preserving
file modes and bytes. Do not merge partial cells or copy runtime directories.
The finalizer rejects missing, extra, symbolic-link, special, mode-drifted,
reordered, failed, copied-process, mixed-host, mixed-build, candidate-drifted,
or digest-broken evidence.

Create a dedicated owner-only publication parent; the tool will never chmod an
existing weaker/shared parent.

```sh
mkdir -m 700 /private/path/assistive-publication
export PORTAVOZ_ASSISTIVE_OUTPUT='/private/path/assistive-publication/authority'

make assistive-qualification-status
make assistive-qualification-finalize
```

Pass `/private/path/assistive-publication/authority/qualification.json` to the
release evaluator. Keep its sibling `authority.json` unchanged and adjacent;
copying or renaming only the generic receipt is invalid. Finalization does not
make the candidate releasable by itself: all other 29-cell release gates still
have to pass for the same exact version, build, commit, and artifact.
