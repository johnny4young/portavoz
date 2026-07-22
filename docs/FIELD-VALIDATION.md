# Privacy-safe field validation

Portavoz's deterministic tests prove policy and recovery behavior, but Core
Audio devices, Apple model services, and real conversational timing still need
field evidence. This protocol captures the minimum diagnostic facts required to
close those gaps without copying meeting content.

## Privacy boundary

Field evidence contains only Portavoz's redacted support format v2 and a
content-free manifest. It must never contain:

- audio, transcripts, summaries, notes, prompts, meeting titles, or speaker names;
- the SQLite library, voiceprints, secrets, configuration, raw errors, or full URLs;
- screenshots or screen recordings unless the meeting participants separately
  consent to that exact capture.

The collector validates every key and value in the support report, rejects
unknown fields, atomically creates a new owner-only evidence directory, and
refuses to inspect `/Applications/Portavoz.app`. Field work uses
`/Applications/Portavoz Dev.app`.

## Before the call

1. Install the validated developer build. Never replace the notarized release
   app while collecting engineering evidence.
2. Choose one scenario below. Do not change several audio variables in one run.
3. Note the start time outside Portavoz without writing participant or meeting
   names into the evidence folder.
4. For cold-model work, release or remove only the disposable developer model
   state needed by that scenario; never alter the release app's data.

## After the call

1. Confirm the recording can stop and reopen before doing any post-call work.
2. Open **Settings → Your data → Support diagnostics** and choose
   **Export redacted support file…**.
3. Run the collector with every observed check. Omitted checks become
   `not-observed`; any failed check makes the scenario outcome `fail`.

```sh
python3 scripts/collect-field-evidence.py \
  --scenario cold-live-captions \
  --report ~/Desktop/portavoz-support.json \
  --output ~/Desktop/portavoz-field/cold-live-captions \
  --check recording-started-before-ready=pass \
  --check captions-attached-without-restart=pass \
  --check pre-attach-audio-recovered=pass \
  --check failure-state-visible=pass \
  --elapsed-seconds 18
```

4. Inspect `manifest.json`: it may contain only scenario/check states, elapsed
   seconds, app/macOS versions, and support-report metadata. Keep
   `support-diagnostics.json` beside it. Do not add free-form notes to the folder.

## Scenario matrix

### `callback-recovery`

Reproduce a complete remote/system callback stall. Observe
`warning-within-eight-seconds`, `microphone-continued`,
`system-timeline-resumed`, and `warning-cleared`. The support report must show a
non-empty microphone channel and the final system-channel shape.

### `airpods-process-tap`

Use AirPods as the active input/output with a recognized call app. Observe
`recognized-app-shown`, `microphone-nonsilent`, `system-nonsilent`, and
`silent-channel-created-no-text`. A digitally silent system channel is a failed
experiment even if the microphone preserved the conversation.

### `cold-live-captions`

Start while the live speech model is not ready. Observe
`recording-started-before-ready`, `captions-attached-without-restart`,
`pre-attach-audio-recovered`, and `failure-state-visible`. Record elapsed seconds
from recording start until the first live caption.

### `live-translation`

Use real Spanish and English turns, then change the translation target. Observe
`same-language-row-unchanged`, `opposite-language-row-translated`,
`target-switch-invalidated-cache`, and `failure-state-visible`. The transcript
must retain each speaker's spoken language; translation is a separate live view.

### `post-capture-refine`

After a normal Stop, run Refine and observe `audio-playable-after-stop`,
`transcript-nonempty`, `speaker-language-preserved`,
`silent-channel-created-no-text`, and `no-repeated-politeness-hallucination`.
This scenario specifically guards against empty transcripts, spurious punctuation,
repeated “Thank you” output, and accidental translation of spoken turns.

### `companion-and-names`

On supported macOS/Apple Intelligence, ask a real knowledge question and use a
calendar-backed attendee set. Observe `question-card-under-five-seconds`,
`directed-ping-detected`, `calendar-suggestion-offered`, and
`remembered-person-offered-not-auto-linked`. Record elapsed seconds to the card.

## Admission rule

A scenario closes a field gap only when every listed check is `pass`, the support
report validates, and the evidence came from the stated real device/call setup.
One successful meeting is useful evidence but is not enough to declare a flaky
Core Audio interaction universally reliable. Failures remain product evidence;
do not delete or reinterpret them as test noise.
