# What's new in Portavoz

Every user-facing feature, newest first. No version numbers yet — dates mark
the order things shipped; entries will fold into versions with the first
public release. (Contributors: any user-visible change adds one short, catchy
entry here — feature name + what it gives you.)

## July 10, 2026

- **⌨️ Dictate anywhere** — Turn it on in Settings and press ⌥⌘D in any app: speak, press it again, and your words are typed right where your cursor is. Same on-device engine as your meetings — your custom vocabulary included — and nothing is ever stored.
- **🎭 Portavoz remembers who sounds like whom** — After you name a speaker, one click remembers their voice; in your next meeting a chip suggests "S1 → Marta?" from the voice alone. Strictly opt-in per person, stored only as an encrypted numeric fingerprint on your Mac (never audio, never synced), forgettable one-by-one or all at once in Settings.
- **🎈 Memory comes back when the work is done** — The big models now unload themselves after idling: the embedded summarizer returned its 2.4 GB two minutes after a summary, Whisper its 1.6 GB after a refine, and the live engines wind down ten minutes after a meeting. Between meetings, Portavoz sits under 200 MB instead of holding gigabytes hostage.
- **🌐 portavoz.app is live** — Portavoz has a home: [portavoz.app](https://portavoz.app), in English and Spanish, with the install command one click away and every performance number reproducible from the repo.
- **✅ Trustworthy refine warnings** — The "refine probably failed" alert no longer fires when the OLD transcript is the broken one (echo-corrupted transcripts claimed more speech than the meeting even lasted). Good refines now pass quietly.
- **🔄 Refine keeps working while you browse** — The quality re-pass now runs per meeting in the background: switch meetings freely and the draft will be waiting when you come back, instead of silently vanishing.
- **🍃 Thin-summary rescue** — When a long meeting produces a suspiciously small summary, a one-click chip offers to retry with the embedded engine. Suggestion only — nothing regenerates on its own.
- **🧠 Smarter built-in brain** — The embedded engine upgrades to Qwen3.5 4B (Apache-2.0, 201 languages): on a real 56-minute meeting it delivered clean Spanish decisions, open questions and 11 owner-tagged action items where the previous model looped and failed. One 3 GB verified download.
- **🎤 Refine no longer steals the room's voice** — With speakers, your mic hears everyone; the quality re-pass was crediting all of it to "Me" (one user showed 52% talk time in a meeting where they barely spoke). Room echo is now detected and dropped, so talk-time stats and "who said what" stay honest.
- **🙏 Fewer phantom "Thank you."s** — Whisper's silence filler is now caught even when background noise breaks its usual rhythm.
- **📋 One action-item list, not three** — Summaries and exports no longer repeat the same action items under different headings.
- **🪞 No more stuttering transcripts** — The live engine's chunk echo ("we added ed a select all all button") is now trimmed as you speak. In a real 56-minute meeting it polluted half the lines; those lines now read clean.
- **🤫 Quiet-mic noise filtered** — A low microphone no longer invents "DDDDD" or "...." caption rows.
- **🃏 Companion cards never overlap** — Long answers scroll in their column instead of painting over the card's footer.
- **👋 Guided first run** — New to Portavoz? A four-step welcome now walks you through permissions, the one-time model download (with a recommendation tuned to your Mac), and optional voice enrollment — so your first recording just works.

## July 9, 2026

- **🧠 Built-in brain** — Summaries with zero installs: pick "Built-in (MLX)" in Settings, download one verified 2.3 GB model, and every summary runs on your Mac's GPU. No Apple Intelligence, no Ollama, nothing ever leaves your machine.
- **🎬 Record from the brief** — One click on "Record this meeting" starts a recording linked to the calendar event: the meeting is born as "2026-07-10 Sprint Demo" — real name, date-prefixed so weekly meetings never collide.
- **⏰ Meeting heads-up** — A floating banner a few minutes before your next calendar meeting: one click starts the linked recording. Configurable in Settings (off / 3 / 5 / 10 minutes); dismiss once, it never nags again.
- **📌 What-to-know, with receipts** — Each brief bullet now cites the meeting it came from (click to jump there), and ungrounded filler ("the meeting will be brief") is filtered out before you see it.
- **🎯 Briefs you can trust** — Related meetings are now ranked by real relevance (hybrid search + threshold) and each one shows WHY it's there ("Mentions: Zephyr, Marta"). Weak matches are dropped instead of shown.
- **✨ Smart titles** — Meetings still named by timestamp get a content-based title suggestion ("QVTL device-ID bug") — one click renames, and titles you wrote are never second-guessed.
- **📅 Prep agenda + briefs** — Today's remaining meetings and tomorrow's, collapsible in the sidebar. Click any of them for its brief: who's coming, related past meetings, what's still open with them, and an on-device "what to know".
- **💬 Ask your meetings** — A chat over everything you've recorded: "what did we agree about the budget?" answered on your Mac, with citations that jump straight to the meeting and moment.
- **🍳 Summaries that fit the meeting** — Standups, 1:1s, planning sessions and interviews each get their own summary structure. Portavoz detects the meeting type and offers it as a one-click chip — or pick any structure from the regenerate menu.
- **✅ To-dos across meetings** — Your open action items from every meeting, right in the sidebar: check them off or click through to their meeting.
- **🧲 Vocabulary that learns** — Portavoz spots recurring names, acronyms and codes in your meetings and suggests them for your vocabulary. Review each one before it lands: fix the spelling if the transcript misheard it, or dismiss it for good.
- **🎈 Compact recording HUD** — Record without the app covering your call: a tiny floating panel with the timer, live captions, mic meter and Stop. Clicks never steal focus from your meeting.
- **📊 Meeting health** — Who talked how much, questions asked, interruptions made, longest monologue — computed entirely on your Mac, right under the summary.
- **🎙️ Live voices, told apart** — Live captions label each remote voice (S1, S2…) as people speak. Two people talking back-to-back are no longer one blurred "Them".
- **🌐 Every speaker keeps their language** — Mixed Spanish/English meetings stay true to each voice in the transcript; summaries still arrive in the language you choose.
- **🤫 No more ghost lines** — Silence no longer invents "Thank you." rows or stray dots in your transcript.

## July 8, 2026

- **🌎 Speaks your language** — Full English/Spanish interface with a live language switch in Settings — no restart needed.
- **📈 Mic level meter** — See how you sound while recording, with a heads-up when your voice is coming in low or far away.
- **🎧 Headphone-proof recording** — Switching audio output mid-meeting (speakers → AirPods) no longer silences the other side of the recording.
- **📋 Copy summary anywhere** — One click copies the summary as plain text, Markdown, or Slack-ready formatting.
- **🎛️ Choose your engine per meeting** — Regenerate any summary with Apple on-device or Ollama, in Spanish or English, without touching your default.
- **💾 Whisper, your size** — A compact 626 MB transcription model for low-disk Macs, with clear model management in Settings.
- **📖 Denser transcript** — Roughly twice the lines per screen, so you read meetings instead of scrolling them.

## July 7, 2026

- **🦙 100% local summaries, no Apple Intelligence required** — Ollama as a first-class summary engine, plus "Recommended for your Mac" advice based on your hardware.
- **🎵 Listen back like lyrics** — A synced player where the transcript scrolls like Spotify lyrics; click any line to jump the audio there.
- **✂️ Clips** — Mark in/out on the waveform and export any moment as audio in under 2 seconds.
- **🌊 Audio, first class** — Channel-colored waveform (you vs. them), skip-silence playback, one-click AAC compression, and drag-and-drop import of external recordings.
- **✍️ Co-authoring notes** — Jot quick notes while the meeting happens; the final summary expands them with facts and marks them as yours (▸).
- **🤝 Live Companion** — Opt-in cards that answer factual questions the room just asked — and a ping when someone says your name. On-device by default; bring your own key if you want a bigger model.
- **🗣️ One-click refine** — Re-transcribe any meeting at maximum quality (Whisper), presented as a draft you compare and approve — never applied behind your back.
- **🧠 Smart summary cache** — Regenerating in another language translates the summary you already have instead of re-summarizing from scratch.
- **📚 Custom vocabulary** — Teach Portavoz your project names and jargon so transcripts and summaries get them right.
- **🌍 Live translated captions** — Follow an English meeting with Spanish captions (or the other way around) while people talk.
- **🏷️ Names, suggested** — Speaker names proposed from your calendar attendees and transcript evidence — applied with one click, never invented.
- **🔐 Your voice, enrolled** — Recognizes you even through a room microphone. Encrypted on device, never synced, deletable in one action.
- **🤖 Ask your meetings** — A local MCP server and on-device RAG chat, so your AI tools can answer "what did I agree to yesterday?".
- **📤 Export everywhere** — Markdown, PDF, secret Gist — and action items that become GitHub or Linear issues.
- **🔎 Search everything** — Full-text search across all your meetings.
- **🛟 Crash-safe recordings** — A force-quit at minute 30 loses at most one second of audio.
- **🔇 Echo cancellation** — On speakers, remote voices no longer leak into your mic as a phantom "Me".
- **📁 Your recordings, your folder** — Choose where audio lives; existing recordings migrate safely.

## July 6, 2026

- **🎬 The foundation** — Dual-channel capture (your mic and the meeting's audio, never mixed), live transcription in under a second, and on-device speaker separation: who-said-what where *your* words are yours by hardware truth. Everything on your Mac — audio never leaves it.
