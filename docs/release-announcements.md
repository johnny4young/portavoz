# Portavoz release announcements

Ready-to-paste announcement texts per release, newest first. English only;
lead with the concrete thing, name the limits, numbers over adjectives.
Short posts are verified at or under 280 characters.

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
