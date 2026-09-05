# Privacy-safe field validation

Portavoz's deterministic tests prove policy and recovery behavior, but Core
Audio devices, Apple model services, and real conversational timing still need
field evidence. This protocol captures the minimum diagnostic facts required to
close those gaps without copying meeting content.

## Privacy boundary

Field evidence contains only Portavoz's redacted support format 2 and a
content-free manifest. It must never contain:

- audio, transcripts, summaries, notes, prompts, meeting titles, or speaker names;
- the SQLite library, voiceprints, secrets, configuration, raw errors, or full URLs;
- screenshots or screen recordings unless the meeting participants separately
  consent to that exact capture.

The collector validates every key and value in each support report, rejects
unknown fields, atomically creates a new owner-only evidence directory, and
refuses to inspect `/Applications/Portavoz.app`. Field work uses
`/Applications/Portavoz Dev.app`.

## Canonical protocol

Protocol 2 packages one named fixture, one pseudonymous meeting reference, and
stable evidence IDs. The support JSON remains format 2; no application schema
change is required.

### Before the call

1. Install the validated developer build. Never replace the notarized release
   app while collecting engineering evidence.
2. Choose exactly one fixture below. Do not change several audio variables in
   one run.
3. Note the start time outside Portavoz without writing participant or meeting
   names into the evidence folder.
4. For model-cold work, release or remove only the disposable developer model
   state needed by that fixture; never alter the release app's data.

### After Stop, before Refine

1. Confirm the meeting reopens and is no longer shown as recording.
2. Open **Settings → Your data → Support diagnostics** and choose
   **Export redacted support file…**.
3. Find the new pseudonymous reference without copying content:

   ```sh
   jq -r '.meetings[-1] | [.reference, .lifecycleState, .transcriptRevision] | @tsv' \
     ~/Desktop/portavoz-before-refine.json
   ```

   Use the last row only when no newer meeting was created after the fixture.

### After Refine

The `mixed-language` fixture requires a second support export after accepting
the refined transcript. Other fixtures may also pair a second report when
Refine is part of the observation. The collector requires the same meeting
reference in both reports, requires the second export to be newer, and refuses a
passing Refine result unless the transcript revision advanced.

Run the collector with every observed evidence item. Omitted items become
`not-observed`; any failed item makes the fixture outcome `fail`.

```sh
python3 scripts/collect-field-evidence.py \
  --fixture mixed-language \
  --report ~/Desktop/portavoz-before-refine.json \
  --after-refine-report ~/Desktop/portavoz-after-refine.json \
  --meeting-reference meeting-0123456789ab \
  --output ~/Desktop/portavoz-field/mixed-language \
  --evidence recording.start.committed=pass \
  --evidence recording.stop.durable=pass \
  --evidence post-capture.admission.completed=pass \
  --evidence translation.live.separated=pass \
  --evidence refine.language.preserved=pass
```

Inspect `manifest.json`: it may contain only the fixture, stable evidence
states/subsystems, elapsed seconds, app/macOS versions, the pseudonymous meeting
reference, and bounded support-report metadata. The package stores
`support-before-refine.json` and, when supplied,
`support-after-refine.json`. Do not add free-form notes to the folder.

## Stable evidence IDs

| Evidence ID | Subsystem | Passing observation |
|---|---|---|
| `recording.start.committed` | recording start | Recording became active without waiting for optional models |
| `capture.route.preserved` | capture route | Participant playback and uplink were unchanged, and both microphone/system assets exist |
| `capture.callback.recovered` | callback recovery | A visible system-callback stall recovered while microphone capture continued |
| `recording.stop.durable` | Stop durability | The meeting reopened in a non-recording durable state |
| `post-capture.admission.completed` | post-capture admission | Finalized audio entered a durable captured/processing/recovery path |
| `translation.live.separated` | live translation | Translation updated in its labeled rail without replacing spoken text |
| `refine.language.preserved` | Refine | The accepted newer revision retained each turn's spoken language |

The collector cross-checks evidence that can be disproved without content. For
example, Stop cannot pass while the selected meeting remains `recording`, route
preservation cannot pass without both channel assets, and post-capture
admission cannot pass without an audio asset. Device perception and language
fidelity remain explicit human observations; the manifest never stores the
words that were heard.

## Fixture matrix

### `built-in-speaker-mic`

Use the built-in microphone and speakers in a real call. Observe recording
start, route preservation, Stop durability, and post-capture admission.

### `airpods`

Use AirPods as the active input and output in a real call. Observe the same four
boundaries as the built-in fixture. A digitally silent system channel or altered
meeting-app uplink is a failed fixture.

### `mixed-language`

Use real Spanish and English turns from different speakers, enable live
translation, Stop, export, Refine, accept, and export again. Observe recording
start, Stop durability, post-capture admission, separate live translation, and
spoken-language preservation after Refine.

### `long-call`

Record a call long enough to exercise unattended capture and finalization.
Observe recording start, route preservation, Stop durability, and post-capture
admission. Record elapsed seconds in the manifest.

### `source-callback-interruption`

Reproduce a complete remote/system callback stall. Observe recording start,
route preservation, callback recovery, Stop durability, and post-capture
admission. Microphone capture must continue while the system lane recovers.

### `model-cold-start`

Start while the live speech model is not ready. Recording must become active
first; Stop must remain durable; finalized audio must enter post-capture
admission so the pre-attachment interval can be recovered.

## Release scorecard

D147 makes field evidence part of a durable, fail-closed release decision.
Before collecting release evidence, choose one version and build and keep that
identity across the deterministic gates, release artifact, and developer build
used for real calls:

```sh
export PORTAVOZ_RELEASE_VERSION=0.8.0
export PORTAVOZ_RELEASE_BUILD=202607280001
export PORTAVOZ_VERSION="$PORTAVOZ_RELEASE_VERSION"
export PORTAVOZ_BUILD="$PORTAVOZ_RELEASE_BUILD"
```

`make install` otherwise defaults the developer bundle to version `0.1.0`,
build `1`; evidence from that identity cannot admit a differently stamped
release. The collector reads the inspected developer bundle and embeds its
actual identity in every protocol-2 manifest.

The tracked contract requires separate built-in and AirPods fixtures on macOS
15 Sequoia and macOS 26 Tahoe. Callback recovery, long-call, and model-cold
fixtures provide real-hardware proof; mixed-language provides user-field
proof. Supply each package explicitly:

```sh
make release-reliability \
  PORTAVOZ_RELEASE_VERSION="$PORTAVOZ_RELEASE_VERSION" \
  PORTAVOZ_RELEASE_BUILD="$PORTAVOZ_RELEASE_BUILD" \
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

The command writes owner-only `readiness.json` and `readiness.md` under
`dist/release-readiness/scorecard`. It exits successfully only when every
contracted deterministic, distribution, real-hardware, and user-field proof is
`pass`. Missing, failed, incomplete, or not-observed cells remain visible and
release-blocking. The scorecard never copies the pseudonymous meeting reference
or support reports.

## Compatibility

Protocol-1 `--scenario` invocations remain accepted for one release and keep
their original manifest and `support-diagnostics.json` filename. New field work
uses `--fixture`, `--evidence`, and protocol 2. This compatibility window lets
existing evidence automation migrate without changing the shipped support
format.

The historical `app-intents-siri` scenario passed on July 27, 2026: the
Portavoz-icon action was visible in the Shortcuts picker, and a saved **Start
Portavoz recording** Shortcut successfully invoked recording from Shortcuts,
Spotlight, and Siri. The same saved Shortcut remained functional after the
unsupported duplicate App Shortcut publication was removed.

## Admission rule

A fixture closes a field gap only when every listed evidence ID is `pass`, every
support report validates, and the evidence came from the stated real device and
call setup. One successful meeting is useful evidence but is not enough to
declare a flaky Core Audio interaction universally reliable. Failures remain
product evidence; do not delete or reinterpret them as test noise.
