# Portavoz Design System

Portavoz is a **privacy-first, 100% local meeting assistant for macOS** (Swift 6 + SwiftUI, iOS next). It records meetings, transcribes live on the Neural Engine, separates voices on-device, and summarizes locally. Two products share one identity:

1. **The macOS app** — native, system-font, indigo-accented, quiet.
2. **portavoz.app** — the marketing site, "the icon's world": dark slate, violet radials, one amber accent, Fraunces display serif.

**Sources** (explore these to design better against the real product):
- GitHub: https://github.com/johnny4young/portavoz — SwiftUI app in `Sources/portavoz-app/`, real site in `site/`, design brief in `docs/design/claude-design-brief.md`, product docs in `docs/`.
- Reference screenshot: `assets/reference/meeting-detail.png` (the repo's showcase seed).

Brand personality: **serio pero cálido, técnico sin frialdad, honesto**. Bilingual ES/EN by birth.

---

## CONTENT FUNDAMENTALS

- **Honest, measured, never salesy.** Claims come with receipts: "Measured, not promised" — every benchmark lists the CLI command that reproduces it. Privacy claims are structural ("your words are yours by hardware design"), not marketing.
- **Bilingual by design.** ES and EN are written as siblings, never machine-mirrored. The site defaults to Spanish. Real-world Spanglish is respected in product content (`deploy`, `PR`, `rollback` stay in English inside Spanish sentences).
- **Sentence case everywhere.** No Title Case headings, no exclamation marks. Em-dashes carry the signature turn: "Sabe quién dijo qué — localmente."
- **Suggestions are questions.** The chip contract in copy: phrased as a question ("S2 → Marta?", "Summarize as Standup?"), applied with one click, never applied alone. Help text always ends with the reassurance: "nothing changes on its own."
- **Deletion is honest**: "Deleted, not gone" — the trash keeps meetings 30 days and says so.
- **You/tú voice**, direct: "build it yourself if you'd rather not take our word." First person plural only for commitments.
- **No emoji in UI.** The only glyph-as-icon is ✦ (sparkles) for AI suggestions and ▸ for co-authored summary lines.
- Example microcopy: "Your history is never hostage." · "Computed on your Mac, from your library — nothing leaves it." · "Or skip — they download on your first recording."

## VISUAL FOUNDATIONS

- **Two palettes, one system.** App: macOS system **indigo** accent (`--accent`, light #5856d6 / dark #5e5ce6) on native neutrals. Web: slate `#0e1120` ground with violet `#5226bf` radial gradients, warm-paper ink `#f3f1ec`, and exactly ONE amber accent `#fdbf47` (the waveform's peak bar). In the **Aurora direction (canonical)** the icon's world enters the app shell in controlled doses: `--aurora-window` (slate→dark gradient), `--aurora-sidebar` (deep glass), `--aurora-header` (violet radial) and `--aurora-selection` (indigo→violet). Amber remains reserved for the user's voice.
- **DS stance on the accent debt:** list selection is INDIGO (`--accent`), never the user's system accent. Resolved here; the app should adopt `.tint` explicitly.
- **Voces (dirección B — «el color ES la voz»):** the user's voice is ALWAYS solid amber (`--voice-me`); every other speaker gets a stable hue (`--voice-1`…`--voice-6`, assigned by order of appearance, persistent per named person) used consistently across pills, talk-time bars, lyrics highlights, player waveform and the web constellation. The UI stays neutral so voice is the only meaningful color; indigo is reserved for system interaction (✦ chips, links, selection).
- **Semantics:** green = mic OK/success · orange = warning (mic low, permissions) · red = destructive/recording dot · ✦ AI suggestion = always accent indigo.
- **Surfaces:** flat quaternary fills (`--surface-card`), no borders, no shadows on cards. Floating panels use material blur + hairline + soft shadow. Backgrounds are solid; gradients exist ONLY as the brand's violet radials on the web.
- **Type:** app = system font (SF Pro), macOS text-style scale (largeTitle.bold pages → title2.bold tile values → headline card titles → caption helpers); numbers ALWAYS tabular (`monospacedDigit`). Web = Fraunces (display, `SOFT 50`, weight 560, amber italics on the em-dash turn) + Instrument Sans (body) + IBM Plex Mono (commands & measured numbers).
- **Spacing:** 12/16/24 core scale (tiles pad 12, cards 16, pages 24). **Radii:** 8 insets · 10 tiles · 12 cards · 14 floating panels · 999 capsules.
- **Motion:** exactly two gestures — `pv-breathe` (3.6s ease-in-out, staggered 0.35s, waveform bars) and `pv-pulse` (1s, recording dot / active mic symbols). Everything else is still. `prefers-reduced-motion` stops both. Hovers: chips deepen their tint (0.14→0.18), buttons brighten slightly, trash rows reveal restore.
- **Capsules are the signature shape:** suggestion chips, speaker pills, mic meters (4pt), talk-time bars — all pill-radius.
- **Imagery:** none. No photos, no illustrations. The waveform IS the imagery.

## ICONOGRAPHY

- **SF Symbols exclusively** in the app (`waveform.and.mic`, `record.circle.fill`, `person.wave.2`, `chart.bar.xaxis`, `sparkles`, `arrow.uturn.backward`…). No icon font, no PNG icons, no emoji.
- The repo ships **no exportable icon assets** — SF Symbols are Apple-licensed and cannot ship on the web. This DS provides `SFIcon`, hand-recreated stroke stand-ins at SF weight whose names mirror the real symbol names (**flagged substitution** — in native code use the real symbols).
- The chosen app icon is **«La P que habla»** — a Fraunces P whose stem IS an amber waveform bar: `assets/portavoz-icon-p.svg` (squircle) + `assets/portavoz-icon-p-menubar.svg` (16px monochrome template; stem pulses red when recording, indigo when dictating). The original waveform-in-a-capsule mark (`assets/portavoz-mark.svg`) remains for the web favicon/legacy.
- Unicode-as-icon: ✦ for AI, ▸ for co-authored lines, · as metadata separator.

## Fonts

No font binaries in the repo; the site loads **Fraunces, Instrument Sans, IBM Plex Mono from Google Fonts** — `tokens/fonts.css` keeps that CDN import (flagged: replace with self-hosted `@font-face` if files are provided). The app font is the system font (SF Pro on Macs); no file needed or shipped.

- **Approved product directions** (from `explorations/UI Refresh Proposals.html`, all rounds approved): Aurora shell for the app (1a/4a) · lyrics-Spotify transcript as the central pattern (live + playback are the same component) · Spotify-style player (waveform = progress, voice-colored) · Settings with sidebar categories + privacy ledger (2a) · rich menu-bar panel (2b) · Insights with clear indicators + heatmap + ✦ findings (3a) · dictation strip with visible target + confirmation (4b) · the four 6a features (⌘K, mirror mode, language bridge, first-listen onboarding — implementation spec in `explorations/6a-implementation-spec.md`).

---

## Index

- `styles.css` — global entry; imports everything in `tokens/`.
- `tokens/` — `colors.css` (app light/dark via `[data-theme="dark"]` + brand), `typography.css`, `spacing.css`, `motion.css`, `fonts.css`.
- `guidelines/` — 12 specimen cards (colors, type, spacing, radii, motion, voice & tone, mark).
- `assets/` — `portavoz-mark.svg`, `reference/meeting-detail.png`.
- `components/` — one directory per family, each with `.jsx` + `.d.ts` + `.prompt.md` + card:

| Component | Path | What |
|---|---|---|
| `Button` | `components/buttons/` | primary / secondary / destructive / ghost · 3 sizes |
| `SuggestionChip` | `components/chips/` | ✦ AI / voice / recipe / title / offer · applied state |
| `SpeakerPill` | `components/pills/` | Me (accent) / named / S-label / editable |
| `Card` | `components/cards/` | stat tile · content card · Companion card |
| `MicMeter`, `Gauge` | `components/meters/` | 4pt mic capsule · circular commitments gauge |
| `ListRow` | `components/rows/` | meeting / to-do / trash+restore / agenda |
| `FloatingPanel` | `components/panels/` | HUD 400×88 · dictation strip 520 · banner |
| `EmptyState` | `components/empty/` | icon + headline + one honest sentence |
| `SFIcon` (+`SF_ICON_NAMES`) | `components/icons/` | SF Symbols stand-ins |

**Intentional additions:** `SFIcon` (SF Symbols can't ship on the web — see Iconography).

- `ui_kits/macos-app/` — interactive app recreation (library with voice-mix rows, meeting detail, insights, recording + HUD).
- `templates/macos-app/`, `templates/website/` — starting-point templates for consuming projects. The website template (bilingual ES/EN, constellation hero, copy-to-clipboard CTA) is the CANONICAL landing — the old ui_kits/website recreation was retired in its favor.
- `SKILL.md` — agent skill entry point.
