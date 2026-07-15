# Spec 06 — macOS App (portavoz-app + packaging scripts)

Status: implemented, signed with Developer ID, **notarized by Apple (0.1.0, Accepted + stapled)** and used in real meetings. Decisions: D20 (SPM + script, no checked-in Xcode project), D23 (packaging), D10 (distribution), D40 (evidence-first launch recovery), D43 (durable Stop), D44 (application dependency ratchet).

## Structure

`portavoz-app` is an SPM `executableTarget` (SwiftUI + Observation, @MainActor). `scripts/make-app.sh [--release]` builds `dist/Portavoz.app`: Info.plist (usage descriptions in English: mic, system audio, calendar, Desktop/Documents/Downloads/removable volumes folders), embeds `Sparkle.framework` + rpath, exports `Resources/Localization/Portavoz/*.xcstrings` to `Contents/Resources/{en,es}.lproj/{Localizable,InfoPlist}.strings`, declares `CFBundleDevelopmentRegion=en` + `CFBundleLocalizations=[en, es]`, signs internal XPCs, hardened runtime (`--options runtime`) + `--timestamp` with real identity + entitlement `com.apple.security.device.audio-input` (without it, the hardened runtime blocks the mic). **No sandbox.**

- Signature: by SHA-1 of cert (`PORTAVOZ_SIGN_IDENTITY`) — there are TWO Developer IDs with the same name on the machine and the name is ambiguous.
- `make-dmg.sh`: DMG UDZO + symlink /Applications; with `PORTAVOZ_NOTARY_PROFILE` notarizes (notarytool + staple).
- `make-release.sh <v>`: stamps version, DMG, `generate_appcast --account portavoz` (dedicated EdDSA key — the default from Keychain is for ANOTHER project), cask with sha256 → `dist/release/`.
- Sparkle 2.9: menu "Buscar actualizaciones…" (`SPUStandardUpdaterController`); `SUFeedURL` points to GitHub release; public key in `assets/sparkle-public-key`.

## Composition — `AppServices` (@MainActor @Observable)

DB (`MeetingStore`) + lazy shared engines: `transcriber` (Parakeet), `diarizer` (with voiceprint if exists; `invalidateDiarizer()` after enroll/delete), `whisper` (lazy, first time downloads verified 1.6 GB with progress). `modelsState` for UI downloads; `libraryVersion` invalidates lists/detail (views reload with `.task(id:)`).

SwiftPM and the XcodeGen UI-test project link `ApplicationKit`. It exposes the
Sendable async `ApplicationUseCase<Request, Response>` contract and admits
StorageKit for its first characterized workflows: `DeleteMeeting` and
`RestoreMeeting` over a narrow `MeetingLifecycleStore` port. `AppServices`
composes both with the real MeetingStore; Library, Meeting Detail, and
Recently Deleted call them instead of writing lifecycle state through the
store. Manual and launch-time purge also use ApplicationKit, coordinating a
pure storage projection with the private app `MeetingAudioFiles` adapter over
RecordingsLocation/FileManager. Slice 2D admits IntelligenceKit only with
`RegenerateSummary`: AppServices composes storage, glossary-preference, and
provider-resolution adapters; Meeting Detail submits one request and maps the
typed completion/cache/unavailability/failure result. Import, refine, and
remaining recording workflows still coordinate capabilities directly until
their own Band 2 slices are characterized and adopted (D44).

**Idle release (Jul 2026)**: engines do NOT stay resident forever. Generation pattern (new use cancels scheduled release): `scheduleWhisperRelease()` (120 s after refine/import; Whisper weighs 1.6 GB) and `scheduleRecordingEnginesRelease()` (600 s after stop/refine/import; doesn't trigger if refine is running). `MLXModelCache` (IntelligenceKit) does the same with Qwen3.5 container (2.4 GB resident measured) at 120 s. Consumers NEVER trust a shared reference after a long await: the durable post-capture worker and `importMeeting` reload with `loadEnginesIfNeeded()` just before diarizing (a scheduled release by another flow could have dropped it in the middle). Note measurement (bench by phases): CoreML weights are file-backed and macOS reclaims them only when no longer used — post-stop footprint drops to ~160 MB without help; explicit release guarantees floor (~140 MB) and releases non-purgeable state.

## Design system in app (Jul 2026) — tokens + voices B + accent

Font: `docs/design/ds/` (authored in Claude Design, pine project). (1) `PVDesign` (app): Swift mirror of `tokens/*.css` — spacing 12/16/24, radios 8/10/12/14, tints 0.14/0.08, brand amber/violet/slate. When a value changes in the DS, it changes THERE and nowhere else. (2) **Voice B direction «el color ES la voz»**: `VoiceHue.index` (IntegrationsKit, pure, FNV-1a — Swift hashValue is randomized by launch and DOESN'T work; 3 tests) assigns stable hue: named by hash of normalized name (same person = same color in all meetings), S-labels by appearance order; `VoicePalette` (app) maps to DS light/dark colors. Applied in: SpeakerPill (Me = solid amber + amber-contrast text; others hue 0.26), MeetingHealth bars (0.85), transcript pills, mic channel of waveform player (amber) and live recording labels. Indigo reserved for interaction (chips ✦, links, selection). (3) **App accent**: `assets/Assets.xcassets/AccentColor` (indigo #5856D6/#5E5CE6) compiled with `xcrun actool` in make-app.sh + `NSAccentColorName` — resolves system-accent debt for multicolor users (macOS gives priority to user who chose explicit color). **DS batch Jul 11 (2nd night — pull 9f11623 + implementation)**: (1) **Icon «La P que habla»**: assets/AppIcon.icns regenerated from DS SVG — the P is Fraunces (NOT installed locally): rendered in browser with Google Fonts via `scripts/icon-p.html` (canvas 1024, macOS grid: square 824 + radius 185) and `scripts/make-icns.sh` builds .icns; menu bar = `assets/icon/pv-menubar-32.png` pre-rendered as NSImage template (MenuBarIcon.swift) — the P adapts to appearance; recording follows record.circle.fill red (the «asta que pulsa» of DS remains flourish web). scripts/make-icon.swift (old icon) removed. (2) **Chips by evidence** (tokens --chip-* new): ChipLabel.swift (ai/voice/offer) + dynamic light/dark tokens in PVDesign (NSColor(name:dynamicProvider:)) — AI = violet tint + spark ✦ AMBER, voice = cyan + waveform, offer = neutral; applied to suggested title, S→name, voice matches, «Summarize as X?» and voice reminder offer. CONTROLS ✦ (Suggest names) follow indigo — deliberate distinction suggestion≠button. (3) **Settings 2a**: NavigationSplitView with 7 categories (SettingsCategories.swift) + search (.searchable filters by title and keyword bags EN/ES — ES live in catalog because EnglishSourceTests scans strings in code) + banner «100% local» → ledger; LedgerSection = real numbers (du of recordings root in Task.detached, count of meetings, enrolled+recorded voices) + honesty line of what actually goes out. gitHubSection extracted to GitHubSection.swift (file_length 700). (4) **Live lyrics 4a**: captionRow with colored voice pills (hash of label — S1/S2 stable, names = canonical hue), active line .title3, YOUR card in amber (me 0.12 + ring 0.35); FocusedTranscriptView already had fade/shrink/blur cylinder. **DS batch Jul 11 (3rd — pull 35264fb: Settings/Menubar/Dictation.jsx + menu bar implementation + mix)**: (1) **Menu bar 2b**: MenuBarContent rewritten as panel `.menuBarExtraStyle(.window)` (previously flat menu) — status header (mini waveform with amber/red peak when recording + «100% local · 0 B a la red hoy» green), quick actions grid (Record red / Dictate indigo / Ask), next meeting card (only if calendar access — never prompt here) with «grabar al empezar» → route .recording(event), recent with relative dates, footer (Open / Launch at login / Quit). Panel closes only on focus loss (opening window closes it). (2) **Voice mix in sidebar** (kit signature): `MeetingStore.voiceMixes(for:)` (StorageKit) — ONE added query that sums segment durations by (meeting, speaker), normalizes to assigned voice of each meeting and returns ordered slices by talk-time (isMe/displayName/fraction/order); 3 tests (fractions sum to 1 + order, empty input, meeting without attributed speech absent). `VoiceMixBar` under each meeting row colors each slice with `VoicePalette.color(for slice:)` — amber = you, stable hue by name, order for S-labels. Meetings without attributed segments simply don't show bar (honest).

**Dictation 4b (pull DS 4 — Jul 11)**: the dictation strip gains the three traits of exploration 4b. (1) **Visible target chip**: `DictationController.targetApp` = `NSWorkspace.frontmostApplication.localizedName` captured in `start()` BEFORE showing non-activating panel (frontmost still is destination app); strip shows `✎ <app>` — never dictate «a ciegas». (2) **Partial in gray**: `confirmedText` in `.primary` + `partialText` in `.tertiary` concatenated (previously joined into one string) — volatility shown in gray and affirmed on confirmation. (3) **Inserted state**: new `Phase.inserted(Int)` — after `TextInserter.insert`, strip shows «N palabras insertadas en <app> — nada se guardó» for 1.6 s before closing (previously closed abruptly). Privacy ledger does NOT adopt the mock DS tile «0 B a la red»: would be an unmeasurable metric (no network log); real LedgerSection says what CAN go out (gists, external model, update check) — more honest («Measured, not promised»).

**Real DS features (Jul 12 — «construyelas»): chapters + only-my-voice + summary tabs + menu-bar pending.** (1) **Summary tabs** (MeetingDetailView): SummarySections (IntegrationsKit, pure, 3 tests) splits markdown by headers `## ` (language-agnostic) → intro + sections with bullet count; tab bar Summary/«Heading·N»/«To-dos·done/total» (active tab indigo filters). (2) **✦ Chapters** (chaptersSection): ChapterExtractor (IntegrationsKit, pure, 6 tests) derives chapters LOCAL from transcript — boundary by pause ≥10s (with minimum spacing of 120s to avoid over-segmenting spaced seeds) or length ≥300s; label = first real sentence of chapter, with fallback search limited to that same chapter; ≤1 chapter → hidden rail. Rendered after MeetingHealth, click seeks+plays (disabled without audio). (3) **Only my voice** (MeetingPlayer + MeetingPlayerBar): `onlyMyVoice` + `nonVoiceRanges` — time-observer skips non-voice ranges like skipSilence; PlaybackRanges.complement (IntegrationsKit, pure, 5 tests) computes complement of .microphone channel ranges within [0,duration] (merge with padding 0.25s); amber-tinted toggle in player bar. (4) **Pending menu bar**: recent shows «✦ N» = openActionItems grouped by meetingID. **2-column layout of detail (Jul 12)**: DONE. loadedBody: header + speakers + refineStatus full-width, then HStack(alignment:.top) — left VStack (summaryOrGenerate + transcriptSection with player, maxWidth infinity) + `detailRail` right (width 260: MeetingHealthView + chaptersSection + Companion persisted). Rail has own scroll and is HIDDEN entirely if no content (doesn't leave 260pt gap). maxWidth of content bumped to 1060. Matches MeetingDetail.jsx from DS.

**Pixel-perfect refinement (Jul 12 — user feedback: app fell short vs DS)**: (1) **Settings** (SettingsSidebar.swift): native one-line nav becomes custom — icon + title + single-line subtitle per category (SettingsCategory.subtitle), selection with indigo→violet gradient, own search field and green «Todo local» badge below, over AuroraSidebarBackground. LedgerSection: 3 rows → 4 tiles (audio/meetings/0 B to the network in green/voices); tile «a la red» = structural (nothing auto-uploads). (2) **Insights** (InsightsView): Swift Charts bar chart replaced by rhythm HEATMAP — LibraryStats.heatmap[week][day] (pure grid, 2 tests) rendered as 12 columns × 7 rows of day with relative indigo intensity to peak; meetings tile gains mini-waveform amber + real week-over-week delta. NO «hallazgos ✦» (no engine, no invention). (3) **Library sidebar** (LibraryView): «New recording» = gradient indigo→violet pill + mini-waveform (amber peak); Import/Ask/Insights = 3 vertical icon+label chips grid; search with keycap ⌘K; footer «100% local — nada sale de tu Mac» with green dot. `accessibilityIdentifier` preserved for XCUITest. **Refinement 2 (Jul 12 — DS screenshots): sidebar timeline + indigo selection + buttons under title.** (1) **MeetingDetail**: the 3 action buttons (refine/export/delete) MOVE from `.toolbar` (top-right) to a ROUND BUTTON ROW under title (actionRow/roundButton) — export tinted accent, delete red; matches DS (buttons live with meeting, not window chrome). (2) **Library sidebar timeline**: meetings grouped by recency (meetingGroups: Today/This week/Last week/Earlier, empty buckets dropped) instead of flat «Meetings». (3) **Indigo selection**: `.tint` does NOT override native sidebar highlight (which follows user's system accent — green on their Mac); solution: `.listRowBackground` with indigo→violet gradient when `route == .meeting(id)` + white text, which beats native highlight. Helpers moved to `extension LibraryView` (type_body_length). Menu bar and detail tabs/chapters/player-chips: DONE (see below).

**Recording 4a (Jul 12)**: RecordingView restructured to DS mockup. `recordingBar` (compact top bar: red dot + timer 24pt + `compactMeter` (mic dB) on left; Translate + Companion (button toggle) + HUD + **Stop red** on right — previously Stop was at bottom and header was 40pt). SINGLE column (previously two): `captionsList` (lyrics, `maxHeight:.infinity`) + ScrollView bounded (260) with companion cards + notes + live summary. `micLowBanner` separated (only when level is low). Language bridge (6a-3): translation under each caption goes in `.secondary` italic (NOT amber — amber only for your voice by voices-B; 6a spec said amber but voices-B is the newer canonical rule). Verification: build/lint/tests; computer-use not applicable (view only exists during live recording with audio engines).

**Recording/review polish (Jul 14)**: local mic mute in bar (zeros aligned, doesn't control call); floating HUD that grows with current utterance and returns to compact on speaker change/pause; unlimited Companion cards newest-first, persisted and reviewable; refine re-derives them; chapter titles with Foundation Models and literal fallback bounded to chapter. `MeetingDetailView` invalidates player/waveform and discards canceled loads when switching meetings so nothing from previous detail leaks into next.

**Aurora shell (Jul 2026)**: `Aurora.swift` — the `--aurora-*` doses of tokens, ONLY in dark appearance (icon world is dark; light stays native). `AuroraDetailBackground` (detail pane, wired in ContentView): 140° gradient #1C1A2E→#262626 + elliptical radial violet with center OUTSIDE screen (x=20%, y=-104pt, 1400×520) — only glow tail touches content; GeometryReader with `ignoresSafeArea` to bleed under toolbar and `.clipped()` to not spill over sidebar. `AuroraSidebarBackground`: brandSlate 0.6 over native vibrancy (deep glass, desktop breathes). Detail views are ScrollView with quaternary translucent fills — gradient breathes through cards without touching them. `--aurora-selection` NOT adopted: macOS draws sidebar selection natively and repainting fights platform.

**Unified accent (same batch)**: `PVDesign.accent = Color.indigo` (system indigo IS exactly the DS hex, adaptive). ALL usage of `Color.accentColor` in app target swept to `PVDesign.accent` — `Color.accentColor` follows user's system accent (not root `.tint`), and produced green/indigo mixes in same view when user has explicit accent. Root `.tint(.indigo)` also reads `PVDesign.accent`. What macOS paints natively (list selection, focus rings) follows user — correct platform behavior.

## Palette ⌘K «Pregúntale a tu semana» (Jul 2026 — design system 6a-1)

`CommandPaletteController` in AppServices (works with closed window) + `NSPanel` Spotlight-style (620 pt, radius 16, `.regularMaterial`, non-activating but key — closes on key loss and state DISCARDED, spec). ⌘K via CommandGroup in menu (works without window). Two lanes: FTS instant while typing (`store.search`, 6 hits with snippet·title·mm:ss, keystroke stale guard) and Enter → full RAG (`AskPipeline.retrieve` + `RAGAnswerer`, answers in question language). Citations as capsules `↗ título · mm:ss` → `pendingRoute` + `pendingSeek` (one-shot consumed by detail after player loads to jump to cited moment) + window reopen ONLY if none visible (openWindow always creates — gotcha). ⌘C copies response+citations in Markdown (`AskMarkdown`, IntegrationsKit). Verified E2E with seed: FTS instant, response IS correct with 6 citations, navigation to detail.

## Insights (Jul 2026) — library dashboard

`Route.insights` (button in sidebar): tiles (meetings, hours, average duration, weekly streak, most active day), weekly cadence chart (Swift Charts, 12 weeks WITH zeros — a chart without empty weeks lies), frequent people and pending gauge. Calculation in two layers: `LibraryStats.compute(meetings:weeks:calendar:now:)` (IntegrationsKit, pure, calendar/now injected, 7 tests — meetings without `endedAt` count but don't drag average) + `MeetingStore.libraryFacts()` (SQL: named non-Me participants across distinct meetings, and counts open/done of action items with same rule latest-snapshot of `openActionItems` to avoid duplicating superseded versions). 100% local; reloads with `libraryVersion`.

## Resident menu bar (Jul 2026)

`MenuBarExtra(isInserted:)` bound to `@AppStorage("menuBarEnabled")` (toggle in Settings → Menu bar, on by default): template icon `waveform.and.mic` that changes to `record.circle.fill` while recording — the "¿estoy grabando?" at a glance. Menu: Start/Stop (Start opens window via `openWindow(id: "main")` + `pendingRoute = .recording(nil)`; Stop calls shared controller), Dictate (only with dictation enabled), Open Portavoz, Launch at login (`SMAppService.mainApp` — requires /Applications, which is the installation story), Quit. **Architectural precondition**: `RecordingController` moved from `@State` of RecordingView to `AppServices.recording` (shared) — view, HUD and menu bar observe THE SAME session and navigation never can orphan a recording (same fix as RefineService).

## Global dictation (Jul 2026)

**Hold-to-talk (Jul 2026)**: `GlobalHotkey` listens to kEventHotKeyPressed AND kEventHotKeyReleased (`GetEventKind` in same handler). Gesture without setting: a TAP (release < 0.5 s) preserves toggle; HOLD combination while speaking and release delivers at release — walkie-talkie. Verified E2E: hold of 2.5 s opens panel on press and closes only on release.

**Configurable hotkey (Jul 2026)**: `HotkeySetting` (keyCode + Carbon mask + label, AppStorage; default ⌥⌘D) + `HotkeyRecorder` in Settings (NSEvent local monitor captures next combo; Esc cancels; combos WITHOUT ⌘/⌥ rejected with beep — single letter as global hotkey would hijack typing). `syncHotkey` now always unregister-first so new combo applies live. Verified E2E: record ⌃⌥⌘M and trigger opens panel.
 — ⌥⌘D in any app

Surface validated by MacParakeet: global hotkey → speak → hotkey again → text written where cursor is. `GlobalHotkey` (Carbon `RegisterEventHotKey` — the only API consuming keystroke WITHOUT Accessibility permission; registered from App init, not view, to survive without window), `DictationController` in AppServices (mic → Parakeet streaming with custom vocabulary → `CaptionCoalescer` reused with echo/noise hygiene; nothing persisted: no meeting, no DB, no file), `DictationPanel` (same non-activating pattern as HUD, bottom-center, live text, X cancels), `TextInserter` (paste-and-restore: clipboard → synthetic ⌘V via CGEvent → restore; the ⌘V DOES require Accessibility — checked BEFORE recording with system prompt to avoid dictating into void). Toggle in Settings (off by default); `DictationAssembler` (TranscriptionKit, pure, tested) joins confirmed+partial. Verified E2E: hotkey triggers with app in background and panel transcribes real live audio; final insertion verified in field.

## Views and flows

**LibraryView**: `New recording` (⌘N), FTS search with snippets, **"To-dos" section** (open action items from ALL meetings via `openActionItems` — checkbox completes in-place and bumps `libraryVersion`; click navigates to meeting; UITests use `firstMatch` because meeting title appears also as caption in these rows), and a list with `Rename`/`Delete` context-menu actions. Library and Meeting Detail deletion plus Recently Deleted restore/permanent purge enter through ApplicationKit use cases; launch cleanup uses the same purge boundary for tombstones strictly older than 30 days. Existing navigation, degradable filesystem behavior, and broad reload semantics remain while scoped observations are pending.

**RecordingView + RecordingController** (full live pipeline):
1. `start`: warm-up of mic (AEC converges during "Preparing…"), engines, then
   one atomic `MeetingStore.beginRecording` write for the `recording` shell and
   pending `<channel>.partial.caf` source assets before `RecordingSession` starts mic (+system tap on
   14.4+). Feeds by channel → Parakeet live → **CaptionCoalescer** (one row per
   intervention). A no-file startup failure rolls back only the empty shell;
   any written channel preserves it as `needsAttention` (D37).
2. Live: captions in LazyVStack (window 150 rows) with **follow-live pausable** (manual scroll pauses; resumes after 10 s or button "Seguir en vivo"); **live voice pills** (S1/S2 — streaming diarization with dedicated instance + `LiveSpeakerLabeler`, spec 03: closed rows split/label by voice as each 10 s window arrives; "Ellos" while no coverage; "Me"→"Yo" via voiceprint); translation picker →es/→en (Translation framework, macOS 15+; only translates closed rows); **rolling monotonic summary** every ~40 s (FM note only of new closed rows → stack → collapse > 6000 chars → render; never shrinks — `LiveSummaryPolicy`) using the independent summary-output policy, never the transcript hint.
3. `stop`: flush and close writers → validate/hash/measure each CAF → atomically
   rename staging files without overwrite → one `installCapturedSnapshot`
   transaction for `captured` + finalized/missing assets + provisional live
   cast/transcript/context/Companion + the exact initial diarization job →
   enter `done` and open detail → process-scoped worker diarizes and atomically
   replaces the provisional cast → optional summary in the independently
   configured language → persist `ready`. The title (configurable
   `TitleTemplate`: `{date} {time} {seq} {weekday}`, ISO-first) is assigned at
   start, so sequence follows start order. `Meeting.language` is set only when
   all segments are homogeneous; mixed/unknown remains nil. Audio with no
   captions, a failed job admission, or later required-work failure remains
   discoverable as `needsAttention` rather than being deleted. A publication
   collision keeps its staging file and also becomes `needsAttention` for
   launch recovery.

Normal Stop now uses the durable process path (D39–D43). A utility-priority
voiceprint read begins after capture reservation and feeds both live
diarization and the exact initial operation. After files publish,
`installCapturedSnapshot(..., enqueue:)` atomically installs captured
assets/live transcript/notes/cards and that first job. Stop enters `done`
immediately after the commit and kicks `PostCaptureProcessingSupervisor`, so
the detail opens while attribution and optional summary continue. A failed job
insert rolls back the snapshot; the controller then attempts one explicit
`needsAttention` snapshot fallback and never deletes audio.

Process launch creates `RecordingRecoveryCoordinator` outside the view
hierarchy. It recovers expired leases, scans non-ready meetings in the
configured and fallback recordings roots, revalidates staging-only or
final-only CAF evidence off the main actor, and commits recovered assets and
lifecycle through StorageKit. Missing files are explicit; staging plus final
or duplicate-root evidence is preserved as `capture.recovery.ambiguous`
without overwrite or deletion. After that pass, the process supervisor resumes
owner-leased diarization/summary work with durable retries and one scheduled
wake instead of polling. The user's post-meeting Shortcut runs after terminal
derived work, including transcript-only completion when summary is unavailable;
temp-store launches suppress real host Shortcuts.

**MeetingDetailView**: header with editable title (pencil), editable speaker pills (capture values on tap — alert-dismiss niled state and rename was lost), chips "Sugerir nombres ✦" with evidence, versioned summary with regenerate (explicit es/en choices persist in the new immutable snapshot), lazy transcript, checkable action items.
- **Refine (D7/D35 in-app)**: re-transcribe both channels with Whisper (+vocabulary). `TranscriptLanguagePolicy.automatic` uses a hint only when previous transcript evidence is homogeneous; if mixed ES/EN, it leaves auto-detection active to preserve speaker/segment language. The per-meeting "Re-transcribe in Spanish/English" choices are explicit fixed recovery operations, and neither the app UI nor summary language is ever a transcript fallback. Refine then re-diarizes (merge micro-clusters) and presents a **DRAFT with comparison sheet** (segments/speakers/speech coverage/sample + red warning if it covers < 50% of current speech) — **nothing is applied without "Aplicar"** (a faulty refine replaced a real meeting; draft flow and tombstones are double defense). On apply, the app replaces `Meeting.language` with the homogeneous language recomputed from refined segments, including `nil` for mixed/unknown output, then calls `replaceCast` and regenerates the summary under its independent policy. **Runs in `RefineService` (Jul 2026), keyed by MeetingID and OUTSIDE view hierarchy**: switching meetings does not lose a draft (the view is recreated with `.id(id)`; previously the Task kept burning ANE and the sheet was lost) — the draft waits for that meeting to be visited again; one refine runs at a time; `MicBleedFilter` discards room echo from the microphone channel. **Chip "Summary looks thin"** (`ThinSummaryPolicy`, pure): meeting ≥ 20 min with summary < 900 chars, or ≥ 40 min with 0 action items → offers regeneration with MLX in one click (only if MLX is downloaded and was not the generator; FM contract: suggestion, never automatic).
- Export: Markdown / PDF (pure CoreText, compiles for iOS) / **Secret Gist** with explicit off-device confirmation.

**SettingsView (⌘,)**: Language (use system language or force English/Spanish, saved in `@AppStorage("app-language")`, applies `\.locale` live to `ContentView` and `SettingsView`) · Intelligence language policies (`transcriptionLanguage`: "Auto-detect" / "English" / "Español" for recognition only; `summaryLanguage`: "Meeting language" / "English" / "Español" for generated output only) · Audio (toggle AEC, preferred mic with visible fallback, capture mode auto/app/system and disclosure of scope) · Recordings (configurable folder with migration and progress) · Titles (template with help popover of tokens, insertable chips, `Reset` button, and live preview) · Vocabulary (list editor: Enter adds, − removes) · My voice (enroll 12 s / delete — destroys file+key) · External model BYOK (endpoint/model in defaults, key in Keychain, Companion opt-in toggle disabled until all configured; deleting key turns it off — spec 04) · GitHub (token in Keychain).

## Verified in real world (Jul 2026)

4 real meetings recorded; TCC permissions stable between updates (real signature identity); 30 min recording survived device change halfway (post-fix); AEC eliminated speaker echo; refine incident recovered without loss.

## Additional as-built note

**Audio first-class (M11/D27) complete**: player synchronized with **Spotify-style lyrics transcript** (`FocusedTranscriptView`: spoken line stays CENTERED in fixed-height viewport, others fade/shrink/blur towards edges — cylinder effect with `.visualEffect`; no scroll bar; search in timeline moves transcript INSIDE its box, never page), click-to-jump, **waveform-scrubber** (colored by channel: accent=you, gray=them; dimmed after playhead; clip region shaded) and **clips** (mark in/out at playhead → `AudioClipExporter` exports mixed range to m4a/AAC via `AVAssetExportSession`, measured well below 2 s) — all in `AudioPlaybackKit`. Without audio, transcript is normal list. The **same carousel runs in live recording** (`FocusedTranscriptView` parametrized with `anchor`: during recording new line focuses at lower third `y≈0.82` — boundary — and old ones rise and fade; `followSignal` re-centers when live line GROWS, not just appears; replaced pausable follow-live). Also: **skip-silence** (toggle; skips gaps ≥1.2 s detected from waveform), **transcode AAC** ("Comprimir audio (AAC)" → `AudioTranscoder`, deletes original after verified write, rebuilds player from m4a) and **import** (library: "Importar audio…" button + drag-drop → `AppServices.importMeeting`: copies as system channel, applies the transcript recognition policy to Whisper, diarizes, summarizes with the independent output policy, and navigates to the new meeting). **M11 complete.** `make test-ui` covers player, highlight and clip export button; preflight closes Portavoz before XCUITest to avoid automation mode failures from stale instances.


## UI verification — XCUITest first (Jul 12)

`make test-ui` (XcodeGen → `Portavoz.xcodeproj` → `xcodebuild test`)
defines 17 XCUITest cases in `Tests/PortavozUITests`: Library (record button +
chips + time grouping + interrupted staging recovery + durable post-capture
resume), Insights (heatmap + interlocutors), Onboarding (first listen +
advance), MeetingDetail (summary tabs reveal ▸, right rail health+chapters,
player skip+only-my-voice, clip export), and Settings (all categories,
independent transcript/summary language controls, custom structures, capture
controls, mirror, and live language switch via ⌘,). Every launch receives a
unique disposable `PORTAVOZ_AUDIO_ROOT` in addition to `-use-temp-store`, so
neither SQLite nor audio can touch the user's library. `-seed-recovery` and
`-seed-processing` are accepted only with the temp store. The processing
fixture uses a deterministic fake local provider and no real audio, models,
biometric files, Keychain, or host Shortcut; it uses the normal exact request
factory and observes the original transcript and dependent summary after launch
resume. Seed-demo includes a third segment at 200 s (mic
channel) so there are two chapters and solo audio. Convention: all new
interactive controls carry `accessibilityIdentifier` (`area-cosa`) plus an
assertion in the corresponding `*UITests.swift`; computer-use is the last
resort. **Real bug caught by XCUITest (not computer-use):**
`PlaybackRanges.complement` built an inverted `ClosedRange` (`200...6`) and
crashed when a voice segment started after audio duration; the fix clamps
before forming the range and has unit coverage.
