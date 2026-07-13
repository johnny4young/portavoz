# What's new in Portavoz

Every user-facing feature, newest first. No version numbers yet — dates mark
the order things shipped; entries will fold into versions with the first
public release. (Contributors: any user-visible change adds one short, catchy
entry here — feature name + what it gives you.)

## July 13, 2026

- **🌍 Live translation that waits its turn** — Turning on live translation no longer lets macOS interrupt your meeting with a language-download prompt out of nowhere. If the language pack isn't installed yet, Portavoz shows a small, dismissable "download once" banner instead — the download only starts when you say so, and never steals focus mid-sentence.
- **🧩 Custom structures** — Beyond the five built-in summary shapes, you can now author your own in Settings ▸ Intelligence — name it (a Hangout, a Brainstorm, a Retro), list its sections one per line, add an optional instruction, and it shows up in every meeting's Structure menu. You can also spin a new one up on the spot from that menu. Edit or delete them anytime.
- **🎧 The player, docked** — In a meeting with audio, the player now sits pinned at the bottom of the transcript, always in reach: the transcript fills the space above it and scrolls on its own, so you never scroll the page to hit play or drag the scrubber. Everything fits the window — no more hunting for the controls.
- **🗣️ Pin your spoken language** — A new "Transcription language" setting (Auto-detect · English · Español) stops a quiet or noisy recording from being transcribed in the wrong language — no more English meeting coming out as Cyrillic. Auto-detect stays the default for clear audio.
- **🌐 Summaries in the meeting's language** — The summary now comes out in the language actually spoken (or the one you pinned), not your Mac's UI language — a Spanish meeting no longer returns an English summary.
- **🔇 A heads-up when the other side isn't captured** — If the incoming audio (the other participants) stays silent while you record — often a Bluetooth-output or permission hiccup — Portavoz now nudges you in real time instead of letting you find out afterward. Dismissable, since in-person meetings have no incoming audio.
- **✏️ Rename that's ready to type** — The rename dialog now opens pre-filled with the current title, already selected, so you can type straight over it or tweak it — no more blank field on the second rename.
- **🏷️ One title, not two** — The meeting title no longer shows twice (window bar + header). It lives in the header where you edit it, and the window bar stays out of the way — a little more room for the meeting itself.
- **✦ Findings from your meetings** — Insights now surfaces what your week is quietly telling you: how much time went to meetings that reached no decision, and the topics that keep coming up across meetings (a real recurring name like "Zephyr", not a stray word) — each with a click that jumps you straight to the meeting. Detected on your Mac from your own transcripts; nothing invented.
- **🛠️ Settings no longer crash** — The Settings window had a stray sidebar-collapse button that was misplaced and, worse, could crash Portavoz when toggled. Settings now uses a clean fixed two-pane layout — no collapse button, no crash.
- **📊 Insights that answer "who, and how much"** — Insights now scopes to this week, month or year (with the delta against the last one), and a new "Who you talk with" panel draws a two-tone bar per person — amber is you, violet is them — so you can see at a glance where you dominate and where you mostly listen. A talk-balance tile sums it up across your whole library. All computed on your Mac.
- **👂 Your first listen** — Onboarding now opens by *doing* instead of describing: say one sentence and watch Portavoz transcribe it live, 100% on your Mac, before a single model has downloaded (it uses macOS's built-in on-device recognizer). Those same 10 seconds can become your enrolled voice with one tap — no need to speak twice — and Skip is always one click away.

## July 12, 2026

- **🪞 Your mirror, after each meeting** — Turn it on and, whenever a real conversation wraps (two or more voices, at least five minutes), Portavoz shows a private card with your own numbers next to your usual average: how much you spoke, questions you asked, times you cut in — plus one plain line of what changed ("You listened more than usual. You asked 2 questions."). Measured, not judged; computed on your Mac; off by default.

## July 11, 2026

- **🎙️ Recording, redesigned** — The live recording view now matches the design: a compact top bar (timer, mic level, Translate, Companion, HUD and a red Stop), then a single column where your words are the interface — the lyrics captions fill the space, with the Companion cards and your notes flowing below.
- **🪟 A two-column meeting** — The meeting view now matches the design: your summary, transcript and player fill the left, while meeting health and the ✦ chapters sit in a rail on the right — the whole meeting readable without scrolling past the numbers.
- **✦ Chapters** — Portavoz now finds the turning points in a meeting on its own — a long pause, or a stretch that has run long — and lists them as chapters you can jump to, each labeled with the line that opens it. Found locally from your transcript; nothing invented.
- **🔊 Play only my voice** — A new toggle in the player skips straight through everyone else and plays only your own turns — replay what YOU said in a long meeting without scrubbing. Rides the same skip engine as "Skip silence".
- **🔖 Tabbed summaries** — The meeting summary now has tabs — Summary, then each section (Decisions · 3, Open questions · 1…) with its count, and To-dos · done/total — so a long summary is something you skim by topic instead of scroll. Parsed from the summary itself, in whatever language it's in.
- **🗂️ A library that reads like a timeline** — Meetings in the sidebar now group by when they happened — Today, This week, Last week, Earlier — and the selected one glows in the brand's indigo→violet gradient instead of your system's accent color, matching the rest of Portavoz.
- **⚡ Meeting actions, front and center** — Refine, export and delete moved from the window's top-right corner to a row of round buttons right under the meeting title — where the meeting is, not tucked in the toolbar.
- **🎬 A library that looks the part** — The sidebar now opens with a violet-gradient "New recording" button carrying a live waveform, Import / Ask / Insights as quick chips, a search field with its ⌘K keycap, and a "100% local" line pinned at the bottom — the design system's shelf-of-conversations, brought into the app.
- **📈 Insights, redrawn** — Your stats now open with a live amber waveform and a real week-over-week delta (▲ +3), and the flat bar chart is now a rhythm heatmap: twelve weeks across, weekdays down, each cell brighter the more you met — your meeting life at a glance, computed on your Mac.
- **⚙️ Settings that guide you** — Each settings category now shows a one-line preview of what's inside, the selected one glows indigo→violet, and "Your data" lays your privacy ledger out as four tiles — audio on disk, meetings, 0 B to the network, voices — so the receipts are right there.
- **⌨️ Dictation that shows where it lands** — The dictation strip now names the app your words will go into (a `✎ Notes` chip), shows the settled words in full color while the still-changing tail stays gray, and confirms with "42 words inserted into Notes — nothing was saved" before it fades. You never dictate blind, and it never leaves a trace.
- **🎚️ See who spoke, right from the library** — Every meeting in the sidebar now carries a slim voice-mix bar under its title: colored segments sized by how much each person spoke, your amber always first. The library becomes a shelf of conversations you can size up at a glance — who dominated, where you barely spoke — without opening anything.
- **📊 A menu-bar panel, not just a menu** — Clicking the menu-bar P now opens a real panel: recording status with a live amber waveform, "100% local · 0 B to the network today", one-tap Record / Dictate / Ask, your next meeting with record-on-start, and recents. Everything one click away with the window closed.
- **🅿️ «La P que habla» — the new face of Portavoz** — The app icon is now a Fraunces P whose stem is an amber waveform bar, standing on the brand's slate-and-violet world. The same P, monochrome, lives in your menu bar and adapts to any wallpaper like a native citizen.
- **⚙️ Settings, reorganized** — No more endless scroll: seven categories with a search field, and a new "Your data" pane whose privacy ledger shows the real numbers — audio on your disk, meetings in your database, voices remembered — plus exactly what ever leaves this Mac (only what you send yourself). "100% local" is now one click from its receipts.
- **🎤 Live captions, lyrics-style** — While recording, the newest line reads big and clear; when it's YOUR voice it glows in an amber card. Every speaker's label is a colored pill — the same stable voice colors as everywhere else — and older lines rise, fade and blur away like song lyrics.
- **✦ Suggestions you can tell apart at a glance** — Suggestion chips are now color-coded by their evidence: AI suggestions wear violet with an amber ✦, voice matches wear cyan with a waveform, and consent offers stay neutral — so a suggestion never looks like a button.
- **🌌 Aurora — the brand enters the shell** — In dark mode the app now wears the icon's world: a slate-violet gradient rising in the window, a soft violet glow bleeding under the toolbar, and a deep-glass sidebar. Controlled doses — your content stays neutral, your voices keep the color. And every accent in the app is now consistently indigo, the product's one accent.
- **🎨 The color IS the voice** — Your voice is now always amber — in speaker pills, the transcript, talk-time bars and the player's waveform — and every other participant gets their own stable hue (Marta is violet in every meeting, forever). Who-said-what and who-talked-how-much now read at a glance, by color. First piece of the new Portavoz design system.
- **✨ ⌘K — Ask your week, anywhere** — Press ⌘K over any view: instant results from your meetings while you type, and Enter brings a full on-device answer with citation chips (`↗ meeting · mm:ss`) that jump straight to the moment. Copy the answer with its receipts in Markdown. Same local engine as "Ask your meetings" — nothing leaves your Mac.

- **🔊 Meetings travel with their audio** — "Export meeting file with audio…" packs the recording into the `.portavoz` file: the receiver gets the synced player, waveform and clips as if they had recorded it. Older Portavoz versions still open the file — they just import the text. Tip: run "Compress audio (AAC)" first for a mail-sized file.
- **🎙️ Hold to talk** — Hold your dictation hotkey down, speak, let go: your words are typed the moment you release — the walkie-talkie way. A quick tap still toggles like before; no setting needed.
- **🗑️ Deleted, not gone** — Deleting a meeting now sends it to "Recently deleted" at the bottom of the sidebar: restore it with one click (transcript, summary, audio — everything comes back), or right-click to delete it permanently. The trash empties itself after 30 days.
- **⌨️ Your dictation, your keys** — The dictation hotkey is now yours to choose: click the recorder in Settings, press any combo (⌃⌥⇧⌘ + key), done. Combos without ⌘ or ⌥ are rejected so a bare letter never hijacks your typing.
- **🗄️ Your whole library, in plain files** — One click in Settings exports every meeting as a readable Markdown file (summary, action items, full transcript) into a folder you choose — read, grep and back them up without Portavoz. Your history is never hostage, now literally.
- **🕐 Recent meetings in the menu bar** — Your three latest meetings, one click away from the menu bar icon.
- **💌 Share a meeting as a file** — Export any meeting as a single `.portavoz` file (transcript, speakers, summary, action items and notes — no audio) and send it to anyone with Portavoz: double-click imports it as a new meeting, exactly as recorded. Import the same file twice and you get two independent copies — nothing ever collides.

## July 10, 2026

- **🎚️ Dictation shows it hears you** — The floating dictation strip now has a live mic meter, so you know your voice is landing before the words appear.
- **📊 Insights** — A new dashboard of your meeting life, computed entirely on your Mac: totals and hours recorded, meetings-per-week cadence, your weekly streak, busiest day, the people you meet most, and how your action items are going. One click in the sidebar.
- **🧹 A tidier to-do sidebar** — The To-dos section now folds away (your choice sticks between launches), and checking off one to-do no longer paints its whole meeting's siblings as selected. Clicking a to-do still jumps to its meeting.
- **🔦 Meetings in Spotlight** — Search a meeting title or a phrase someone said right from Spotlight (⌘Space); one click opens the exact meeting. The index is your Mac's local one — nothing leaves the machine.
- **📍 Portavoz in your menu bar** — A glanceable icon that turns into a red dot while recording, with one-click start/stop, dictation, and "Launch at login". Close the window: recording, hotkey and menu keep working. Turn it off in Settings if you like your menu bar lean.
- **🤖 Meetings that file themselves** — Name a Shortcut in Settings and every finished meeting runs it with the full Markdown (summary, action items, transcript) as input: straight to Notes, Mail, Slack — anything Shortcuts reaches. And any automation tool can start a recording by opening `portavoz://record`.
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
