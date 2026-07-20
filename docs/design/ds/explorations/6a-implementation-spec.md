# 6a — Implementation specification (for Claude Code)

Specifications for the 4 ideas from round 6a of the `explorations/UI Refresh Proposals.html` canvas.
Context: macOS app built with Swift 6 + SwiftUI, repo https://github.com/johnny4young/portavoz.
Everything runs on-device; no feature may introduce network traffic.

---

## 1 · ⌘K «Pregúntale a tu semana»

**What it is:** a global command palette (Spotlight/Raycast style) over any app view that answers natural-language questions about the user's history using the existing local RAG.

**Where it connects to the code:**
- Reuse `RAGAnswerer` (IntelligenceKit) and `MeetingStore.search` (FTS5) — the pipeline already exists in `AskView.swift`; this is a new surface over the same engine.
- Global hotkey: follow the `GlobalHotkey.swift` pattern (currently registers ⌥⌘D for dictation). Default: ⌘K within the app; optional global hotkey in Settings.
- Panel: floating nonactivating `NSPanel` (same recipe as `RecordingHUD.swift` / `DictationPanel.swift`), 620pt wide, radius 16, `.regularMaterial`.

**Behavior:**
1. ⌘K opens the panel with focus in the input. `esc` closes it. State is discarded on close.
2. While typing: instant FTS5 (titles + snippets, <25 ms). Enter: full RAG answer.
3. Answer = brief synthesis (2-3 sentences, facts in bold) + citation chips `↗ {título} · {mm:ss}` — clicking navigates to `Route.meeting(id)` and seeks the player to that timestamp.
4. `tab` limits the scope to the open meeting. `⌘C` copies the answer with citations in Markdown.
5. Bilingual: answer in the language of the question.

**Acceptance criteria:** first answer < 4 s with FM; every claim in the answer has ≥1 citation; works with the main window closed (independent panel); zero network traffic.

---

## 2 · Mirror mode (honest post-meeting coach)

**What it is:** an opt-in card that appears when meeting processing finishes, presenting the user's metrics in the brand voice — «medido, no juzgado». Never evaluative language («mal», «demasiado»); only numbers + comparison with the user's own average.

**Where it connects:**
- Data: `MeetingHealth.compute(segments:)` already calculates talk time, questions, and interruptions by speaker — filter on `isMe`.
- Personal average: add to `LibraryStats` (ApplicationKit) an average talk share over the last N meetings (persist nothing new: compute from the library).
- Presentation: sheet/card when the post-meeting summary completes (the hook where `RecordingController` enters the completed phase), nonblocking.
- Setting: `Settings › Mi voz y Companion › «Espejo al terminar» (off por defecto)`.

**Card content:** 3 tiles (`% hablaste` versus your average, highlighted in amber if it differs by >10pts; `preguntas hiciste`; `interrupciones` with whom and a clickable timestamp) + 1 ✦ line of FM synthesis (max 2 sentences, fact-based template: you listened more/less than usual, what remained open for you) + actions: «Ver mi tendencia» (→ Insights) and «No mostrar tras cada reunión».

**Criteria:** appears only with ≥2 speakers and ≥5 min; never appears if the setting is off; the ✦ text never uses evaluative adjectives.

---

## 3 · Live language bridge

**What it is:** during recording, beneath each final caption in language A, its translation into the user's preferred language appears in a smaller secondary track in amber. The original leads; the bridge accompanies it.

**Where it connects:**
- `LiveTranslation.swift` (portavoz-app) and the «Translate» picker in `RecordingView` already exist — this is a presentation redesign, not a new engine.
- Translate ONLY finalized (nonvolatile) segments to avoid flicker; queue them with `IntelligenceScheduler` in a background lane.
- Glossary: pass `VocabularyPrompt.parse(customVocabulary)` so jargon (deploy, PR, QVTL…) remains intact.

**Presentation (lyrics pattern):** original line = current carousel style; below it, indented to the start of the text (not the pill), 15px, `--brand-amber`/`.orange` color at 90%, same alignment. If the translation arrives >2 s late, it fades in and never reorders lines.

**Criteria:** bridge latency < 3 s p95; toggle in the recording bar («Traducir: off / ES / EN»); vocabulary jargon is never translated; off = zero cost.

---

## 4 · Onboarding «primera escucha»

**What it is:** replaces the current 4 steps in `OnboardingView.swift` with a first-person demo: the user says a sentence and sees live transcription → voice separation → mini-summary, BEFORE permissions are requested.

**Flow:**
1. Single screen: breathing waveform + «Di una frase — mira lo que pasa.» Single button «Escuchar 10 s». (Request mic permission here, inline, with one line explaining why.)
2. Capture 10 s with `MicrophoneSource` + live Parakeet (if the model is unavailable, use the system SpeechAnalyzer so a download does not block the demo).
3. Show live: caption appearing (lyrics pattern) → amber «Tu voz» pill → card with the localized status «✓ transcrita en X s · ✓ voz separada · ✦ resumen de una línea», ending with «todo sin red, como acabas de ver».
4. Only then: remaining permissions (system audio is requested on the first real recording, as it is today), optional calendar, and an offer to enroll the voice by reusing the audio JUST recorded (one click, not another 12 s).
5. `hasOnboarded` remains as a flag; «Saltar» is always visible (brand voice: frictionless, no dark patterns).

**Criteria:** from app launch to completed demo < 60 s; works without downloading models (SpeechAnalyzer fallback); demo audio is discarded unless the user agrees to enroll their voice; ES/EN according to system language.

---

## Cross-cutting notes

- All new UI uses the design system tokens (`tokens/colors.css` as the value reference; in SwiftUI: indigo accent, amber = the user's voice only, semantic green/orange/red).
- Numbers always use `monospacedDigit`. Bilingual copy via `L10n`.
- ✦ chips preserve the contract: they propose, one click applies, they never act alone.
