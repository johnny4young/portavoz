// Demo data for the Portavoz macOS UI kit — mirrors the repo's showcase
// seed (assets/reference/meeting-detail.png).
window.PV_DATA = {
  meetings: [
    { id: "m1", title: "2026-07-10 Sprint Demo · Zephyr", date: "10 Jul 2026 at 10:00 AM", min: 42, segments: 9, mix: [{ v: "me", w: 24 }, { v: 1, w: 38 }, { v: 2, w: 25 }, { v: 0, w: 13 }] },
    { id: "m2", title: "2026-07-09 Sync semanal QVTL", date: "9 Jul 2026 at 10:00 AM", min: 31, segments: 7, mix: [{ v: "me", w: 45 }, { v: 1, w: 35 }, { v: 0, w: 20 }] },
    { id: "m3", title: "2026-07-08 1:1 con Marta", date: "8 Jul 2026 at 10:00 AM", min: 28, segments: 6, mix: [{ v: "me", w: 52 }, { v: 1, w: 48 }] },
    { id: "m4", title: "2026-07-07 Retro sprint 14", date: "7 Jul 2026 at 10:00 AM", min: 47, segments: 11, mix: [{ v: "me", w: 18 }, { v: 1, w: 30 }, { v: 2, w: 32 }, { v: 3, w: 20 }] },
    { id: "m5", title: "2026-07-04 Kickoff Aurora Suite", date: "4 Jul 2026 at 10:00 AM", min: 55, segments: 12, mix: [{ v: "me", w: 35 }, { v: 2, w: 40 }, { v: 0, w: 25 }] },
  ],
  todos: [
    { id: "t1", text: "Migrar los dashboards de Kepler antes del viernes", meeting: "2026-07-10 Sprint Demo · Zephyr" },
    { id: "t2", text: "Review the Aurora Suite English docs draft", meeting: "2026-07-10 Sprint Demo · Zephyr" },
    { id: "t3", text: "Preparar la demo del cliente para el lunes", meeting: "2026-07-10 Sprint Demo · Zephyr" },
  ],
  trashed: [
    { id: "d1", title: "2026-06-30 Prueba de audio", caption: "27 days left" },
  ],
  speakers: [
    { name: "Me", me: true }, { name: "Marta", voice: 1 }, { name: "Ilarion", voice: 2 }, { name: "S3" },
  ],
  summaryLede: "La demo del sprint validó la build 214 de Zephyr sobre el cluster de pruebas y cerró el bug del device-ID duplicado en QVTL (cache del provisioning, verificado contra 40 dispositivos).",
  decisions: [
    { text: "La beta de Zephyr sale el lunes; Marta lidera la demo con el cliente." },
    { text: "Congelar el scope del sprint 15: Zephyr beta, dashboards Kepler y docs de Aurora Suite.", coauthored: true },
    { text: "El fix del device-ID queda verificado y cerrado." },
  ],
  openQuestions: [
    "¿El presupuesto de transcripción del Q3 cubre el crecimiento del lab?",
  ],
  health: [
    { name: "Marta", voice: 1, share: 0.38, time: "0:42", pct: "38%" },
    { name: "Ilarion", voice: 2, share: 0.25, time: "0:28", pct: "25%" },
    { name: "Me", voice: "me", share: 0.24, time: "0:27", pct: "24%" },
    { name: "S3", share: 0.13, time: "0:14", pct: "13%" },
  ],
  transcript: [
    { t: "00:12", who: "Marta", voice: 1, text: "Arranquemos con el estado de Zephyr: el cluster de pruebas ya corre la build 214 y el pipeline quedó verde anoche." },
    { t: "00:54", who: "Me", me: true, text: "Perfecto. ¿Cerramos entonces el bug del device-ID duplicado en QVTL?" },
    { t: "01:24", who: "Ilarion", voice: 2, text: "Sí, era el cache del provisioning. El fix está en main y lo verificamos contra los 40 dispositivos del lab." },
    { t: "02:18", who: "Marta", voice: 1, text: "Queda pendiente migrar los dashboards de Kepler antes del viernes — eso bloquea la demo con el cliente." },
    { t: "03:00", who: "Me", me: true, text: "Lo tomo yo. También quiero que revisemos el presupuesto de transcripción del Q3." },
    { t: "03:48", who: "Ilarion", voice: 2, text: "On that note — the English docs for Aurora Suite are ready for review, I shared the draft this morning." },
    { t: "04:36", who: "Marta", voice: 1, text: "Genial. Propongo congelar el scope del sprint 15 hoy: Zephyr beta, dashboards Kepler y las docs de Aurora." },
    { t: "05:30", who: "S3", text: "Desde infraestructura sin novedades: el failover de la región secundaria pasó el drill sin downtime." },
    { t: "06:18", who: "Me", me: true, text: "Entonces decidido: beta de Zephyr sale el lunes y Marta lidera la demo con el cliente." },
  ],
  insights: {
    tiles: [
      { value: "128", label: "meetings" }, { value: "96 h", label: "recorded" },
      { value: "45 min", label: "avg length" }, { value: "12", label: "week streak" },
      { value: "Tue", label: "busiest day" },
    ],
    weeks: [3, 5, 4, 6, 2, 7, 5, 8, 6, 4, 7, 9],
    people: [
      { name: "Marta", meetings: 34 }, { name: "Ilarion", meetings: 21 },
      { name: "Priya", meetings: 12 }, { name: "Diego", meetings: 9 },
    ],
    actionItems: { done: 9, total: 14 },
  },
};
