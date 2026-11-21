# Portavoz Design System

Portavoz is a **privacy-first, local-first meeting assistant for macOS** (Swift 6 + SwiftUI, iOS next). It records meetings, transcribes live on the Neural Engine, separates voices on-device, and summarizes locally by default; remote providers and private iCloud sync require explicit opt-in. Two products share one identity:

1. **The macOS app** — native, ink on paper, quiet; Fraunces for titles and display numerals, SF for everything else.
2. **portavoz.app** — the marketing site, "the icon's world": dark slate, violet radials, one amber accent, Fraunces display serif.

**Sources** (explore these to design better against the real product):
- GitHub: https://github.com/johnny4young/portavoz — SwiftUI app in `Sources/portavoz-app/`, real site in `site/`, design brief in `docs/design/claude-design-brief.md`, product docs in `docs/`.
- Reference screenshots: `assets/screenshots/` (the repository's fictional
  `-seed-showcase` library, regenerated from app-window-only XCUITest evidence
  with `make public-screenshots`).

Brand personality: **serious but warm, technical without being cold, honest**. Bilingual ES/EN from the outset.

---

## CONTENT FUNDAMENTALS

- **Honest, measured, never salesy.** Claims come with receipts: "Measured, not promised" — every benchmark lists the CLI command that reproduces it. Privacy claims are structural ("your words are yours by hardware design"), not marketing.
- **Bilingual by design.** ES and EN are written as siblings, never machine-mirrored. The site defaults to Spanish. Real-world Spanglish is respected in product content (`deploy`, `PR`, `rollback` stay in English inside Spanish sentences).
- **Sentence case everywhere.** No Title Case headings, no exclamation marks. Em-dashes carry the signature turn: "Sabe quién dijo qué — localmente."
- **Suggestions are questions.** The chip contract in copy: phrased as a question ("S2 → Marta?", "Summarize as Standup?"), applied with one click, never applied alone. Help text always ends with the reassurance: "nothing changes on its own."
- **Deletion is honest**: "Deleted, not gone" — the trash keeps meetings 30 days and says so.
- **Direct second-person voice**: "build it yourself if you'd rather not take our word." First person plural only for commitments.
- **No emoji in UI.** The only glyph-as-icon is ✦ (sparkles) for AI suggestions and ▸ for co-authored summary lines.
- Example microcopy: "Your history is never hostage." · "Computed on your Mac, from your library — nothing leaves it." · "Or skip — they download on your first recording."

## VISUAL FOUNDATIONS

- **Ink on paper (app).** Paper `#fbf7f2` / Night `#121615` surfaces with ink `#14201e` / `#eeebe2`. Chrome carries no hue: primary buttons, selection and focus are ink (`--accent: var(--ink)`). The web keeps its own slate ground and violet radials in `site/styles.css`; the Aurora shell doses are retired.
- **Shared with Secreteo:** amber `#f2b33d`, paper `#fbf7f2` / `#f4ece3`, green `#1f6f5c` / `#7fd1b9` and the light red `#b93a22`.
- **Voices («color IS voice»):** you are ALWAYS amber (`--you`, `--you-ink` for amber text); up to five others get a stable hue (`--voice-1`…`--voice-5`: Cobalt, Madder, Moss, Clay, Lagoon), assigned by order of appearance and persistent per named person; `--voice-unnamed` is grey. Voice hues are fills; names stay ink on the tint.
- **Semantics:** red (`--now`) = the present only (Record, Stop, live edge, now line), never a warning · green (`--green`) = Portavoz speaking (✦ chips, summaries, answers, translations) · `--ok` = success · warnings and errors = ink plus a glyph.
- **Surfaces:** solid paper, sunk paper for sidebars, cards on `--card`; no gradients in the app, no left-edge accent strips (tint, weight or a full outline instead).
- **Type:** app = bundled Fraunces for display roles (`PVDisplayStyle`: countdown 172/340 SOFT 100, page and meeting titles 40/480, section heads 21/520, heard quotes 19 italic; SOFT 40 elsewhere, WONK off) and SF Pro for body and controls, SF Mono for time codes. Fraunces has no tabular figures, so ticking time uses equal digit cells; SF numbers stay tabular (`monospacedDigit`). Web = Fraunces (display, `SOFT 50`, weight 560, amber italics on the em-dash turn) + Instrument Sans (body) + IBM Plex Mono (commands & measured numbers).
- **Spacing:** 12/16/24 core scale (tiles pad 12, cards 16, pages 24). **Radii:** 8 insets · 10 tiles · 12 cards · 14 floating panels · 999 capsules.
- **Motion:** exactly two gestures — `pv-breathe` (3.6s ease-in-out, staggered 0.35s, waveform bars) and `pv-pulse` (1s, recording dot / active mic symbols). Everything else is still. `prefers-reduced-motion` stops both. Hovers: chips deepen their tint (0.14→0.18), buttons brighten slightly, trash rows reveal restore.
- **Capsules are the signature shape:** suggestion chips, speaker pills, mic meters (4pt), talk-time bars — all pill-radius.
- **Imagery:** none. No photos, no illustrations. The waveform IS the imagery.

## ICONOGRAPHY

- **SF Symbols exclusively** in the app (`waveform.and.mic`, `record.circle.fill`, `person.wave.2`, `chart.bar.xaxis`, `sparkles`, `arrow.uturn.backward`…). No icon font, no PNG icons, no emoji.
- The repo ships **no exportable icon assets** — SF Symbols are Apple-licensed and cannot ship on the web. This DS provides `SFIcon`, hand-recreated stroke stand-ins at SF weight whose names mirror the real symbol names (**flagged substitution** — in native code use the real symbols).
- The app icon is **three voice strands**, the amber one (you) swelling widest, on the shared squircle grid: `assets/portavoz-icon.svg` (dark) + `assets/portavoz-icon-light.svg` + `assets/portavoz-mark-menubar.svg` (monochrome template; the middle swell turns red while recording). All three are generated from the app's `PortavozMark` geometry by `scripts/make-icons.sh` — edit the geometry, not the SVGs. The original waveform-in-a-capsule mark (`assets/portavoz-mark.svg`) remains for legacy explorations.
- Unicode-as-icon: ✦ for AI, ▸ for co-authored lines, · as metadata separator.

## Fonts

No font binaries in the repo; the site loads **Fraunces, Instrument Sans, IBM Plex Mono from Google Fonts** — `tokens/fonts.css` keeps that CDN import (flagged: replace with self-hosted `@font-face` if files are provided). The app font is the system font (SF Pro on Macs); no file needed or shipped.

- **Approved product directions** (from `explorations/UI Refresh Proposals.html`; every round is approved except 4b, the dictation strip, which was withdrawn): Aurora shell for the app (1a/4a, since retired for ink on paper) · lyrics-Spotify transcript as the central pattern (live + playback are the same component) · Spotify-style player (waveform = progress, voice-colored) · Settings with sidebar categories + privacy ledger (2a) · rich menu-bar panel (2b) · Insights with clear indicators + heatmap + ✦ findings (3a) · the four 6a features (⌘K, mirror mode, language bridge, first-listen onboarding — implementation spec in `explorations/6a-implementation-spec.md`).

---

## Index

- `styles.css` — global entry; imports everything in `tokens/`.
- `tokens/` — `colors.css` (app light/dark via `[data-theme="dark"]` + brand), `typography.css`, `spacing.css`, `motion.css`, `fonts.css`.
- `guidelines/` — 12 specimen cards (colors, type, spacing, radii, motion, voice & tone, mark).
- `assets/` — `portavoz-icon.svg`, `portavoz-icon-light.svg`, `portavoz-mark-menubar.svg` (generated), `portavoz-mark.svg` (legacy).
- `components/` — one directory per family, each with `.jsx` + `.d.ts` + `.prompt.md` + card:

| Component | Path | What |
|---|---|---|
| `Button` | `components/buttons/` | primary / secondary / destructive / ghost · 3 sizes |
| `SuggestionChip` | `components/chips/` | ✦ AI / voice / recipe / title / offer · applied state |
| `SpeakerPill` | `components/pills/` | Me (accent) / named / S-label / editable |
| `Card` | `components/cards/` | stat tile · content card · Companion card |
| `MicMeter`, `Gauge` | `components/meters/` | 4pt mic capsule · circular commitments gauge |
| `ListRow` | `components/rows/` | meeting / to-do / trash+restore / agenda |
| `FloatingPanel` | `components/panels/` | HUD 400×88 · banner |
| `EmptyState` | `components/empty/` | icon + headline + one honest sentence |
| `SFIcon` (+`SF_ICON_NAMES`) | `components/icons/` | SF Symbols stand-ins |

**Intentional additions:** `SFIcon` (SF Symbols can't ship on the web — see Iconography).

- `ui_kits/macos-app/` — interactive app recreation (library with voice-mix rows, meeting detail, insights, recording + HUD).
- `templates/macos-app/`, `templates/website/` — starting-point templates for consuming projects. The website template (bilingual ES/EN, constellation hero, copy-to-clipboard CTA) is the CANONICAL landing — the old ui_kits/website recreation was retired in its favor.
- `SKILL.md` — agent skill entry point.
