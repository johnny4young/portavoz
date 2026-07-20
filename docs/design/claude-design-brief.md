# Portavoz Design System — brief for Claude Design

> Paste this brief as the first message in a **Design system** project on
> claude.ai/design. It describes the real product, the de facto tokens currently
> in the code, the surface inventory, and the structural conventions that the
> subsequent sync (`/design-sync`) expects.

## The product

Portavoz is a **privacy-first, 100% local** meeting assistant for
macOS (Swift 6 + SwiftUI, with iOS coming next). It records meetings, transcribes
live, separates voices on-device, and summarizes locally. Brand personality:
**serious but warm, technical without being cold, honest** ("measured, not
promised", "your history is never hostage"). Bilingual ES/EN from the outset.

## De facto tokens (what is in the code TODAY — a starting point, not dogma)

**Color (macOS app)**
- Global tint: system `indigo` (controls, links, active icons).
- Suggestion chips: `accentColor.opacity(0.14)` in a capsule; secondary
  offer at `0.08`.
- Cards/tiles: `quaternary.opacity(0.5)`, radii 10 (tiles) and 12 (cards).
- Floating panels: `.regularMaterial`, radius 14.
- Semantics: green = mic OK / success; orange = warning (low mic,
  permissions); red = destructive/recording (menu bar dot).
- ⚠️ Known debt: list selection uses the user's SYSTEM accent
  (green on my Mac) and clashes with indigo — the design system must
  establish a position.

**Color (portavoz.app website — the "icon's world")**
- Slate background `#0e1120` → violet radial gradients `#5226bf`.
- Single amber accent `#fdbf47` (the waveform peak bar).
- Warm-paper text `#f3f1ec`, secondary `#b9b6c4`.

**Typography**
- App: system font (SF Pro); numbers ALWAYS `monospacedDigit`; hierarchy
  used: largeTitle.bold (page titles), title2.bold (tile
  values), headline (card titles), caption/caption2 (helper text).
- Web: Fraunces (display serif, SOFT axis 50) + Instrument Sans (body) +
  IBM Plex Mono (commands and numbers).
- Open question for the DS: how much of the web identity (Fraunces/amber)
  should enter the native app without conflicting with native macOS conventions?

**Iconography**: SF Symbols exclusively (waveform.and.mic,
record.circle.fill, person.wave.2, chart.bar.xaxis, sparkles ✦ for
AI suggestions, arrow.uturn.backward for restore).

**Motion**: pulse on active symbols (dictation); CSS waveform "breathe"
for 3.6s on the web, respecting `prefers-reduced-motion`.

## Real surface inventory (all exist today)

1. **Library** (sidebar): action buttons, search, collapsible
   sections (To-dos, Recently deleted), meeting rows, agenda.
2. **Meeting detail**: speaker pills (Me = accent), suggestion CHIPS
   (names ✦, voice 🎙, recipe, title, thin-summary — the product's
   most repeated pattern: pure suggestion, click applies it, never acts alone),
   structured summary with "▸" co-authorship, action items with checkboxes,
   meeting health (talk-time bars), dense transcript with pills.
3. **Live recording**: timer, lyrics-style caption carousel, mic meter
   (4pt capsule, dB mapping −60→0), notes, Companion cards.
4. **Floating HUD** (400×88) and **dictation panel** (520×~70): material,
   always on top, mic meter, live text.
5. **Insights**: stat tiles (large value + caption label), weekly bar
   chart (Swift Charts), people cards, and circular gauge for
   commitments.
6. **Onboarding** (4 steps), **Settings** (16 sections in a grouped Form),
   **menu bar** (status icon + menu), **Ask** (chat with citations).
7. **Web** (portavoz.app): hero waveform, features grid, measured numbers,
   footer.

## What I am asking of the design system

1. **Foundations**: a unified palette that reconciles app-indigo + web-amber/slate
   with light/dark modes; type scale; spacing (today: 12/16/24);
   radii (today: 10/12/14); semantics (success/warning/destructive/
   recording/AI-suggestion).
2. **Components** (with variants per card):
   - Suggestion chip (AI ✦ / voice / recipe; hover; applied).
   - Card (stat tile, content card, Companion card).
   - Speaker pill (Me / named / S-label / editable).
   - Meter (mic level OK/low; circular gauge).
   - List row (meeting, to-do with checkbox, trash with restore).
   - Button (primary/secondary/destructive/ghost; sizes).
   - Floating panel (HUD, dictation strip, pre-meeting banner).
   - Empty states (empty library, no commitments, trash).
3. **Voice and tone**: bilingual microcopy with the personality ("Deleted, not
   gone", "Measured, not promised").

## Conventions for the subsequent sync (important)

- The project MUST be created as the **Design system** type (the type is
  immutable — a regular project cannot be converted).
- One component = one **self-contained** preview HTML file (inline CSS, no
  CDNs) with the card marker on the FIRST line:
  `<!-- @dsCard group="Components" -->` — the pane groups by that `group`.
- Suggested groups: `Foundations` (Colors, Type, Spacing), `Components`,
  `Patterns` (chips/suggestions), `Surfaces` (panels/HUD), `Brand` (web).
- Stable path structure: `foundations/colors/index.html`,
  `components/chip/index.html`, etc. — sync is incremental by
  component; stable paths = clean diffs.
- Variants of a component in ONE card (the subtitle lists them), not one card
  per variant.
