# Portavoz release announcements

Ready-to-paste announcement texts per release, newest first. English only;
lead with the concrete thing, name the limits, numbers over adjectives.
Short posts are verified at or under 280 characters.

## v1.5.1 — 2026-11-12

A lighter patch: a 29% smaller download, and model and audio checks that no longer load whole files into memory.

### X / Bluesky — 255 characters

Portavoz 1.5.1: the download drops from 36.8 to 26.1 MB (no debug symbols), model and pre-Refine audio checks stop loading whole files into memory, and shared Parakeet models stay on disk while something still uses them. macOS 26+. https://portavoz.app

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v1.5.1
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v1.5.1/Portavoz-1.5.1.dmg

## v1.5.0 — 2026-11-06

Speech models live in one shared folder on your Mac, so each one downloads once for every build and app that uses it.

### X / Bluesky — 279 characters

Portavoz 1.5.0: speech models now live in one shared folder on your Mac, so every build and app that uses them downloads each model once. Your existing models move there without a new download, and Settings shows each model's size and which apps share it. https://portavoz.app

### Hacker News

**Title:** `Portavoz 1.5 – download each on-device speech model once per Mac`

**Text:**

Portavoz runs transcription, speaker separation and summaries on the Mac, which means hundreds of megabytes of models. Until 1.5 each copy of the app kept its own: the release build, a development build and any other app using the same models each downloaded and stored them again.

1.5.0 moves them into one shared folder per Mac. The models already on disk move there on the first launch, without a new download, and every model is still checked against a pinned SHA-256 before it is used. Settings lists the models on this Mac, how much room each one takes and which other apps use it, so removing one is an informed choice.

Limits: the folder is shared per Mac, not synced anywhere, and a model you never downloaded still downloads on first use. Like 1.3 and 1.4, this release requires macOS 26 Tahoe.

Site: https://portavoz.app. Source: https://github.com/johnny4young/portavoz.

### Reddit (r/macapps, r/LocalLLaMA)

**Title:** `Portavoz 1.5.0: on-device speech models shared across apps on your Mac, downloaded once`

**Text:**

Portavoz (MIT, on-device meeting assistant and dictation for macOS) 1.5.0 is out.

- Models live in one shared folder, so the release build, a dev build and other apps using the same models download each one once.
- Existing models move there without a new download.
- Settings lists each model's size and which apps share it.

Requires macOS 26 Tahoe. `brew install --cask johnny4young/tap/portavoz` or the notarized DMG. https://portavoz.app

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v1.5.0
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v1.5.0/Portavoz-1.5.0.dmg

## v1.4.0 — 2026-11-05

When another app already handles dictation, Portavoz steps aside instead of pasting twice.

### X / Bluesky — 276 characters

Portavoz 1.4.0: if another app already handles dictation on your Mac, Portavoz says so, never pastes twice, and switches back with one click. Also: a quiet "Sí" or "OK" stays in the transcript, and thinking models stop leaking reasoning into summaries. https://portavoz.app

### Hacker News

**Title:** `Portavoz 1.4 – a macOS dictation app that steps aside when another one is active`

**Text:**

Two dictation apps answering the same shortcut paste the same sentence twice. In 1.4.0, when another app handles dictation on the Mac, Portavoz says so in Settings and the menu bar and does not paste. One click switches dictation back to Portavoz. It never takes the role on its own.

Two fixes came from real transcripts. A quiet "Sí", "OK" or "De acuerdo" was being dropped as noise; short answers now stay in. And local or cloud models that reason before answering, through Ollama or a provider, could break the summary format or leak their reasoning into it. Portavoz now keeps only the answer and says plainly when the model ran out of room instead of returning a truncated summary.

Smaller: the update window shows the release notes before you update, an old recording notification can no longer stop a newer recording, and the Homebrew install no longer prints a deprecation warning.

Requires macOS 26 Tahoe. Site: https://portavoz.app. Source: https://github.com/johnny4young/portavoz.

### Reddit (r/macapps, r/LocalLLaMA)

**Title:** `Portavoz 1.4.0: on-device dictation that steps aside when another dictation app is active`

**Text:**

- If another app handles dictation, Portavoz says so, never pastes twice, and lets you switch back with one click.
- Short answers ("Sí", "OK") stay in the transcript instead of being dropped as noise.
- Ollama and cloud models that think before answering no longer break summaries or leak their reasoning.
- The update window shows the notes for the new version.

MIT, macOS 26 Tahoe. https://portavoz.app

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v1.4.0
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v1.4.0/Portavoz-1.4.0.dmg

## v1.3.0 — 2026-11-02

Dictation that polishes, rewrites and translates with the model already on your Mac.

### X / Bluesky — 256 characters

Portavoz 1.3.0: Polish fixes grammar and false starts with the model on your Mac, recipes rewrite any text you select (⌃⌥⌘R), "change Friday to Monday" fixes the last paste by voice, and English ↔ Spanish translation runs on-device. https://portavoz.app

### Hacker News

**Title:** `Portavoz 1.3 – on-device dictation that polishes, rewrites and translates (macOS)`

**Text:**

Portavoz started as a meeting assistant; 1.3.0 is mostly about dictation. The design rule is the same: nothing leaves the Mac unless you point a feature at an external provider.

Polish is a text mode that fixes grammar, punctuation and false starts with the summary engine you already use for meetings (the bundled local model, Apple Intelligence or Ollama). Recipes shape it: Formal, Friendly, Bullet list, Concise, or your own. The same recipes work on any text you select in any app: press ⌃⌥⌘R or say how to rewrite it, check the preview, press Return. Nothing replaces your text without that preview.

Corrections are scoped on purpose. Start a dictation with "change Friday to Monday" and it edits only what Portavoz just pasted, not the document. "Always write" makes it spell a word your way from then on. Dictation history exists but is opt-in; once on, you can search it, ask about it, and add entries to a meeting's notes.

Honest limits. 1.3.0 requires macOS 26 Tahoe; Sequoia stays on 1.2.0. Polish is only as good as the local model you have, and translation is English ↔ Spanish only. Parakeet Ultra becomes the dictation default only after you download it; nothing downloads on its own.

Site: https://portavoz.app. Source: https://github.com/johnny4young/portavoz.

### Reddit (r/macapps, r/LocalLLaMA, r/opensource)

**Title:** `Portavoz 1.3.0: open-source macOS dictation that polishes, rewrites and translates on-device`

**Text:**

- **Polish** fixes grammar, punctuation and false starts with your local model; recipes: Formal, Friendly, Bullet list, Concise or your own.
- **Rewrite anything you select** in any app with ⌃⌥⌘R, with a preview before it replaces.
- **Fix by voice**: "change Friday to Monday" edits only the last paste.
- **English ↔ Spanish** translation of dictations and meeting transcripts, on your Mac.
- **Opt-in dictation history**: searchable, shareable with local agents, scriptable from Shortcuts.
- Meetings: a remembered voice names the speaker (one Undo clears it), Refine skips silence and stops inventing words.

Requires macOS 26 Tahoe (Sequoia keeps 1.2.0). MIT. https://portavoz.app

### Platform notes

> 1.3.0 requires macOS 26 Tahoe. Macs on macOS 15 Sequoia or earlier stay on 1.2.0.

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v1.3.0
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v1.3.0/Portavoz-1.3.0.dmg

## v1.2.0 — 2026-10-20

Dictation that keeps up: an optional, more accurate model, hold Fn to talk, and no lost first word.

### X / Bluesky — 256 characters

Portavoz 1.2.0: an optional Parakeet Ultra dictation model (613 MB) with a third fewer word errors, hold Fn to dictate, the mic opens the moment you press the shortcut, and an on-device voice detector keeps silence out of your text. https://portavoz.app

### Hacker News

**Title:** `Portavoz 1.2 – on-device macOS dictation that doesn't lose your first word`

**Text:**

1.2.0 is the release where Portavoz's dictation got serious. The most visible problem was the first word: if the model was still loading when you pressed the shortcut, the start of the sentence was gone. Now the microphone opens immediately and buffers while the model loads, and an hourglass tells you to keep talking.

The optional Parakeet Ultra model is a 613 MB download you can cancel. It makes about a third fewer word errors than the default and handles mixed English and Spanish much better. Meetings keep using the regular Parakeet model; Ultra is for dictation only.

Two small decisions I would defend. "Paste last" keeps the last dictation for 15 minutes so you can paste it again if it landed in the wrong place, but only in memory; it is gone when the Mac sleeps or locks. And a tiny on-device voice detector decides whether there was speech at all, so silence and background noise never paste as text.

Limits: 1.2.0 is qualified on macOS 26 Tahoe; 1.1.0 is the last release officially supported on Sequoia. Ultra needs the download and the disk space.

Site: https://portavoz.app. Source: https://github.com/johnny4young/portavoz.

### Reddit (r/macapps, r/LocalLLaMA)

**Title:** `Portavoz 1.2.0: on-device dictation for macOS with an optional larger model and hold-Fn-to-talk`

**Text:**

- **Parakeet Ultra** (optional, 613 MB): about a third fewer word errors, much better mixed EN/ES.
- **Hold Fn**, Right Option or Right Command to dictate; let go to paste.
- The mic opens instantly, even while the model loads.
- "Stop after a pause" for hands-free, with an on-device voice detector that keeps silence out.
- **Paste last** within 15 minutes, memory only.
- An audio import queue for several files at once.

MIT, qualified on macOS 26 Tahoe. https://portavoz.app

### Platform notes

> 1.2.0 is qualified on macOS 26 Tahoe. 1.1.0 is the last release officially supported on macOS 15 Sequoia.

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v1.2.0
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v1.2.0/Portavoz-1.2.0.dmg

## v1.1.0 — 2026-09-18

Less noise: one line of status while you record, a meeting page where the transcript gets the room, and Settings in seven panes.

![Meeting detail](https://portavoz.app/assets/screenshots/meeting-detail.png)

### X / Bluesky — 273 characters

Portavoz 1.1.0 is about less noise: one line of status while you record instead of a stack of banners, a meeting page where the transcript gets the room, Today led by your next call, and Settings cut to seven panes. Plainer words, one icon per idea. https://portavoz.app

### Hacker News

**Title:** `Portavoz 1.1 – removing UI from a macOS meeting assistant`

**Text:**

After 1.0 I went through every screen asking what could go. The recording bar had grown a stack of banners; it now keeps Translate, Apuntador (the in-meeting assistant) and Catch me up in view, tucks the rest into a More menu, and shows only the one notice that matters now.

The meeting page gives summary, commitments and notes only the space they need, so the transcript gets the rest. People, Apuntador and Chapters share one side column with a lens picker. Privacy and action history moved into a small chip under the title instead of repeating on every panel.

Words changed too: "sources" instead of "evidence", "activity" instead of "receipts". Warnings now look different from errors (orange circle versus red triangle), and each idea has one icon across the app.

It is a reorganization, not new capability: if you knew where something was in 1.0, it may have moved. Site: https://portavoz.app. Source: https://github.com/johnny4young/portavoz.

### Reddit (r/macapps)

**Title:** `Portavoz 1.1.0: a quieter macOS meeting assistant, fewer banners and a meeting page that fits your screen`

**Text:**

- One line of status while you record instead of stacked banners.
- The meeting page gives the transcript the room; side panels share one column.
- Today leads with your next meeting: countdown, brief, record button.
- Settings in seven panes, in a window you can resize.
- Plainer words and one icon per idea; warnings look different from errors.

MIT, on-device. https://portavoz.app

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v1.1.0
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v1.1.0/Portavoz-1.1.0.dmg

## v1.0.1 — 2026-09-16

Fixes the crash that ended a fresh 1.0.0 install at its first recording.

### X / Bluesky — 251 characters

Portavoz 1.0.1 fixes a crash that ended a fresh 1.0.0 install at its first recording: the app looked for its bundled question model where it was built instead of inside the app. If Portavoz quit when you pressed record, update. https://portavoz.app

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v1.0.1
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v1.0.1/Portavoz-1.0.1.dmg

## v1.0.0 — 2026-09-12

First major release: the day ahead on Today, the meetings behind answered with cited evidence, and Skills that propose while you confirm.

![Today view](https://portavoz.app/assets/screenshots/today.png)

### X / Bluesky — 263 characters

Portavoz 1.0.0 is out. A meeting assistant for macOS that records both sides of the call, transcribes live, tells voices apart and answers questions with cited evidence, all on your Mac. Today view, Commitment Radar, review-first Skills. MIT. https://portavoz.app

### Hacker News

**Title:** `Show HN: Portavoz 1.0 – a macOS meeting assistant that never uploads your audio`

**Text:**

I've been building Portavoz for the past year and 1.0.0 shipped this week. It is a native Swift 6 app for macOS that records a meeting as two separate channels (your mic and the meeting app's audio), transcribes live on the Neural Engine with Parakeet, separates speakers on-device, and summarizes with a local model. Nothing leaves the Mac unless you explicitly point a feature at an external provider.

The part I care most about in 1.0 is Ask. It answers questions about your meeting history with evidence first: exact full-text search runs before any semantic recall, every claim carries a citation that jumps the player to the exact second, and you choose the sources per question (your meetings, your typed notes, one public web page you name, and which local engine answers). Answers stream as they are written and stop at a deadline instead of hanging.

The other design decision: Portavoz proposes, you confirm. Commitments detected in a meeting wait for your confirmation before they become to-dos or reminders. Skills that would touch the outside world (a GitHub or Linear issue, an email recap, a secret Gist) show you exactly what they will do, run only after review, and leave a receipt that reopens its source. Approvals expire.

Honest limits. macOS Sequoia or later on Apple silicon only; there is no iOS app yet. Private iCloud sync exists but is opt-in and I have not finished qualifying it across two Macs, so treat it as beta. The bundled local summarizer is a 4B model; Apple Intelligence or Ollama give better summaries if you have them. It is direct download only (notarized DMG or Homebrew cask), not on the App Store, and it is MIT licensed.

Since 0.7.0 in July the changelog has about 170 user-visible entries, mostly reliability: recordings survive a mic or headphone switch, a busy disk, a transcription hiccup at Stop, and a crash mid-processing. The native test suite is 3,115 tests, and the UI is exercised by real-app XCUITest in English and Spanish from one build.

Site: https://portavoz.app. Source: https://github.com/johnny4young/portavoz. I would like to hear where the source policy for Ask feels wrong, and whether the confirm-first model is too much friction.

### Reddit (r/macapps, r/opensource, r/LocalLLaMA)

**Title:** `Portavoz 1.0.0: open-source macOS meeting assistant, transcription + diarization + cited answers, 100% on-device`

**Text:**

After two months of reliability work since 0.7.0, Portavoz 1.0.0 is out. Native Swift 6, MIT, macOS Sequoia+ on Apple silicon.

- Records your mic and the meeting app's audio as two channels, so your words are yours by hardware truth.
- Live transcription with Parakeet on the Neural Engine, speaker separation on-device, summaries with a bundled local model, Apple Intelligence or Ollama.
- **Today** view: agenda with countdown, a brief and a linked recording per event, open to-dos, one-click questions.
- **Ask**: exact search first, optional local semantic recall, citations that jump to the exact second, sources chosen per question.
- **Commitment Radar**: promises detected in meetings wait for your confirmation, then can become reminders.
- **Skills**: GitHub/Linear issues, email recaps, secret Gists, only after review, with receipts.
- Siri and Shortcuts start/stop recordings, Spotlight indexes your private work, a local MCP server lets your AI tools ask about your meetings.

Limits: no iOS, iCloud sync is opt-in and still beta, direct download only (no App Store).

Install: `brew install --cask johnny4young/tap/portavoz` or the notarized DMG. https://portavoz.app

### Platform notes

> macOS Sequoia (15) or later on Apple silicon. Direct download only: notarized DMG or Homebrew cask, no App Store. Private iCloud sync is opt-in and not yet qualified across two Macs.

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v1.0.0
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v1.0.0/Portavoz-1.0.0.dmg

## v0.7.0 — 2026-07-28

Call-safe capture, multilingual captions that stay in the language spoken, and live help while the room waits.

### X / Bluesky — 233 characters

Portavoz 0.7.0: call-safe capture that never takes over your mic, captions kept in the language each person spoke, and live catch-up, suggested questions and talk balance during the meeting. On-device by default. https://portavoz.app

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v0.7.0
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v0.7.0/Portavoz-0.7.0.dmg

## v0.6.0 — 2026-07-15

The Companion's live answers are saved with the meeting, and you choose exactly which audio Portavoz captures.

### X / Bluesky — 251 characters

Portavoz 0.6.0: live Companion answers now survive the recording and travel with the meeting file. Pick your mic and what counts as the meeting app, mute your side to Portavoz without muting the call, and skimmable chapter titles. https://portavoz.app

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v0.6.0
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v0.6.0/Portavoz-0.6.0.dmg

## v0.5.1 — 2026-07-14

Field fixes: calls on AirPods record the other side again, plus custom summary structures.

### X / Bluesky — 240 characters

Portavoz 0.5.1: recording a call on AirPods used to drop the other participants (Bluetooth mic mode). Fixed. Also custom summary structures, re-transcribe in the right language, and no invented text on a silent channel. https://portavoz.app

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v0.5.1
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v0.5.1/Portavoz-0.5.1.dmg

## v0.5.0 — 2026-07-13

A new design system across the whole app, with your voice always amber and every other participant in a stable hue.

### X / Bluesky — 261 characters

Portavoz 0.5.0: the whole app wears a new design. Your voice is amber everywhere (pills, transcript, waveform), other voices get stable hues, a two-column meeting view with tabbed summaries, and lyrics-style live captions. Still 100% local. https://portavoz.app

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v0.5.0
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v0.5.0/Portavoz-0.5.0.dmg

## v0.4.0 — 2026-07-11

Recently deleted with one-click restore, meeting files that carry their audio, and hold-to-talk dictation.

### X / Bluesky — 235 characters

Portavoz 0.4.0: deleted meetings go to Recently deleted and come back whole, .portavoz exports can carry the audio so the receiver gets the synced player, and hold your dictation hotkey to talk walkie-talkie style. https://portavoz.app

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v0.4.0
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v0.4.0/Portavoz-0.4.0.dmg

## v0.3.0 — 2026-07-11

Meetings become portable files, the whole library exports as Markdown, and the dictation hotkey is yours to choose.

### X / Bluesky — 246 characters

Portavoz 0.3.0: export any meeting as a single .portavoz file (transcript, speakers, summary, notes), dump your whole library to readable Markdown in one click, pick your own dictation hotkey, recent meetings in the menu bar. https://portavoz.app

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v0.3.0
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v0.3.0/Portavoz-0.3.0.dmg

## v0.2.0 — 2026-07-11

Dictate in any app, voice memory that suggests who is speaking, a menu bar icon, Spotlight search and Insights.

### X / Bluesky — 246 characters

Portavoz 0.2.0, one day after 0.1.0: press a hotkey and dictate into any app with the same on-device engine, opt-in voice memory that suggests speaker names, menu bar control, meetings in Spotlight, and an Insights dashboard. https://portavoz.app

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v0.2.0
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v0.2.0/Portavoz-0.2.0.dmg

## v0.1.0 — 2026-07-10

First public release: dual-channel capture, live on-device transcription, speaker separation and local summaries.

### X / Bluesky — 266 characters

Portavoz 0.1.0, first public release. Records your mic and the meeting audio as separate channels, transcribes live on the Neural Engine, separates speakers on-device (DER 7.6% on an AMI sample), summarizes with local engines. No cloud, no bots. https://portavoz.app

### Links

- Release: https://github.com/johnny4young/portavoz/releases/tag/v0.1.0
- Site: https://portavoz.app
- Source: https://github.com/johnny4young/portavoz
- `brew install --cask johnny4young/tap/portavoz`
- Notarized DMG: https://github.com/johnny4young/portavoz/releases/download/v0.1.0/Portavoz-0.1.0.dmg
