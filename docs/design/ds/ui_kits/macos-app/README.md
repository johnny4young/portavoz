# macOS app UI kit

Interactive recreation of the Portavoz macOS app (dark appearance), grounded in
the real SwiftUI sources at `Sources/portavoz-app/` of
https://github.com/johnny4young/portavoz and the reference screenshot at
`assets/reference/meeting-detail.png`.

- `index.html` — the shell: sidebar routing, HUD overlay, dark window frame.
- `Sidebar.jsx` — LibraryView: action buttons, search, Today/To-dos/Meetings/Recently deleted.
- `MeetingDetail.jsx` — MeetingDetailView: title ✦ chip, speaker pills + "S3 → Priya?" flow, summary card with coauthored "▸", action-item checkboxes, meeting health bars, dense transcript.
- `Insights.jsx` — InsightsView: stat tiles, weekly bar chart, people card, commitments gauge.
- `Recording.jsx` — RecordingView (timer, lyrics captions, Companion card) + the 400×88 floating HUD.
- `Settings.jsx` — the 2a redesign: left nav + search, the "all local" seal, an Intelligence pane with the honest Apple-Intelligence recommendation, grouped rows, and the "Panel de tus datos" privacy ledger (its own `settings.card.html`).
- `Menubar.jsx` — the 2b rich menu-bar panel: live-waveform bar icon (amber peak), status, quick actions, next meeting, recents (its own `menubar.card.html`).
- `Dictation.jsx` — the 4b dictation strip: one floating panel sharing the HUD material that morphs dictating → inserted (no trace) → honest warning (its own `dictation.card.html`).
- `data.js` — demo data mirroring the repo's showcase seed.

Interactions that work: sidebar navigation, meeting selection (indigo, the DS
stance), to-do checkboxes (shared state sidebar↔summary), ✦ title & name chips
(click applies, then the "Remember voice?" offer appears), HUD toggle from the
recording view. Only the 2026-07-10 Sprint Demo is seeded in full — the DS
stance on demo honesty.
