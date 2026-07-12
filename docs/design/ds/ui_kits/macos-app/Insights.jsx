// Insights dashboard — aligned with the approved 3a design: clear indicators,
// labeled rhythm heatmap, ✦ findings, per-relation talk balance.
const pvInsights = window.PV_DATA.insights;

const PV_WEEK_COLS = [
  [1, 2, 1, 0, 2], [2, 3, 1, 2, 0], [1, 2, 3, 1, 2], [0, 1, 2, 3, 1],
  [2, 0, 1, 2, 3], [1, 3, 2, 0, 1], [2, 1, 3, 2, 0], [0, 2, 1, 3, 2],
  [1, 0, 2, 1, 3], [2, 1, 0, 2, 1], [3, 2, 1, 0, 2], [4, 3, 3, 2, 3],
];
const PV_HEAT = [
  "var(--surface-card-soft)",
  "color-mix(in srgb, var(--accent) 14%, transparent)",
  "color-mix(in srgb, var(--accent) 28%, transparent)",
  "color-mix(in srgb, var(--accent) 50%, transparent)",
  "var(--accent)",
];

function PVIndicators() {
  return (
    <div style={{ display: "flex", gap: 12 }}>
      <div style={{ flex: 1, padding: "13px 14px", borderRadius: 12, background: "var(--surface-card)", display: "flex", alignItems: "center", gap: 11 }}>
        <div style={{ display: "flex", alignItems: "flex-end", gap: 2.5, height: 28 }}>
          {[0.4, 0.55, 0.7, 1].map((f, i) => (
            <span key={i} style={{ width: 5, height: `${f * 100}%`, borderRadius: 99, background: i === 3 ? "var(--accent)" : "color-mix(in srgb, var(--accent) 40%, transparent)" }}></span>
          ))}
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 1 }}>
          <span style={{ font: "700 20px/1.2 var(--font-app)", fontVariantNumeric: "tabular-nums", color: "var(--text-primary)" }}>9 <span style={{ font: "600 11px/1 var(--font-app)", color: "var(--success)" }}>▲ +3</span></span>
          <span style={{ font: "var(--type-caption)", color: "var(--text-secondary)" }}>reuniones vs semana anterior</span>
        </div>
      </div>
      <div style={{ flex: 1, padding: "13px 14px", borderRadius: 12, background: "var(--surface-card)", display: "flex", flexDirection: "column", gap: 1, justifyContent: "center" }}>
        <span style={{ font: "700 20px/1.2 var(--font-app)", fontVariantNumeric: "tabular-nums", color: "var(--text-primary)" }}>3.3 h <span style={{ font: "600 11px/1 var(--font-app)", color: "var(--text-tertiary)" }}>▼ −0.8</span></span>
        <span style={{ font: "var(--type-caption)", color: "var(--text-secondary)" }}>grabadas · 22 min de media</span>
      </div>
      <div style={{ flex: 1, padding: "13px 14px", borderRadius: 12, background: "var(--surface-card)", display: "flex", alignItems: "center", gap: 11 }}>
        <div style={{ position: "relative", width: 36, height: 36, borderRadius: 999, background: "conic-gradient(var(--voice-me) 0 42%, var(--fill-quaternary) 42% 100%)", flexShrink: 0 }}>
          <div style={{ position: "absolute", inset: 6, borderRadius: 999, background: "var(--bg-window)", display: "flex", alignItems: "center", justifyContent: "center", font: "700 8px/1 var(--font-app)", color: "var(--text-primary)" }}>42%</div>
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 1 }}>
          <span style={{ font: "600 13px/1.2 var(--font-app)", color: "var(--text-primary)" }}>Balance de habla</span>
          <span style={{ font: "var(--type-caption)", color: "var(--text-secondary)" }}>hablas 42% · escuchas 58% — sano</span>
        </div>
      </div>
      <div style={{ flex: 1, padding: "13px 14px", borderRadius: 12, background: "color-mix(in srgb, var(--warning) 8%, transparent)", boxShadow: "inset 0 0 0 1px color-mix(in srgb, var(--warning) 30%, transparent)", display: "flex", alignItems: "center", gap: 11 }}>
        <div style={{ position: "relative", width: 36, height: 36, borderRadius: 999, background: "color-mix(in srgb, var(--warning) 20%, transparent)", flexShrink: 0 }}>
          <div style={{ position: "absolute", inset: 6, borderRadius: 999, background: "var(--bg-window)", display: "flex", alignItems: "center", justifyContent: "center", font: "700 8px/1 var(--font-app)", color: "var(--warning)" }}>{pvInsights.actionItems.done}/{pvInsights.actionItems.total}</div>
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 1 }}>
          <span style={{ font: "600 13px/1.2 var(--font-app)", color: "var(--warning)" }}>Pendientes ⚠</span>
          <span style={{ font: "var(--type-caption)", color: "var(--text-secondary)" }}>{pvInsights.actionItems.total - pvInsights.actionItems.done} abiertos — revisar hoy</span>
        </div>
      </div>
    </div>
  );
}

function PVFindings() {
  const items = [
    { title: "«Trinity» apareció en 4 reuniones — y sigue sin decisión.", body: "3 preguntas abiertas apuntan al mismo tema.", cta: "✦ Ver las 4 menciones" },
    { title: "1.4 h esta semana en reuniones sin ninguna decisión.", body: "Los dos syncs del jueves cerraron sin decisiones ni pendientes.", cta: "✦ ¿Cuáles fueron?" },
    { title: "«¿El presupuesto Q3…?» lleva 2 semanas sin respuesta.", body: "La hiciste tú el 27 jun y reapareció el 9 jul.", cta: "✦ Preguntar a mi historial" },
  ];
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10, padding: 16, borderRadius: 12, background: "var(--surface-card-soft)" }}>
      <div style={{ display: "flex", alignItems: "baseline", gap: 10 }}>
        <span style={{ font: "var(--type-headline)", color: "var(--text-primary)" }}>Hallazgos ✦ de tu semana</span>
        <span style={{ font: "var(--type-caption)", color: "var(--text-tertiary)" }}>detectados localmente en tus transcripts — cada uno con su acción</span>
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 10 }}>
        {items.map((it) => (
          <div key={it.cta} style={{ display: "flex", flexDirection: "column", gap: 5, padding: "11px 13px", borderRadius: 10, background: "var(--surface-card)" }}>
            <span style={{ font: "600 12px/1.4 var(--font-app)", color: "var(--text-primary)" }}>{it.title}</span>
            <span style={{ font: "var(--type-caption)", color: "var(--text-secondary)" }}>{it.body}</span>
            <span style={{ font: "600 10px/1 var(--font-app)", color: "var(--accent)", background: "var(--accent-tint-14)", borderRadius: 999, padding: "5px 9px", alignSelf: "flex-start", cursor: "pointer" }}>{it.cta}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function PVRhythm() {
  return (
    <div style={{ flex: 1.2, display: "flex", flexDirection: "column", gap: 8, padding: 16, borderRadius: 12, background: "var(--surface-card-soft)" }}>
      <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
        <span style={{ font: "var(--type-headline)", color: "var(--text-primary)" }}>Tu ritmo · 12 semanas</span>
        <span style={{ font: "var(--type-caption)", color: "var(--text-tertiary)" }}>columna = semana · fila = día laboral · más intenso = más reuniones</span>
      </div>
      <div style={{ display: "flex", gap: 7, flex: 1, alignItems: "center" }}>
        <div style={{ display: "grid", gap: 4, font: "500 9px/13px var(--font-mono)", color: "var(--text-tertiary)", textAlign: "right" }}>
          {["L", "M", "X", "J", "V"].map((d) => <span key={d} style={{ height: 13 }}>{d}</span>)}
        </div>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(12, 1fr)", gap: 4, flex: 1 }}>
          {PV_WEEK_COLS.map((col, ci) => (
            <div key={ci} style={{ display: "grid", gap: 4 }}>
              {col.map((v, ri) => <span key={ri} style={{ height: 13, borderRadius: 3, background: PV_HEAT[v] }}></span>)}
            </div>
          ))}
        </div>
      </div>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", font: "400 9px/1 var(--font-mono)", color: "var(--text-tertiary)" }}>
        <span>20 Abr</span><span>1 Jun</span>
        <span style={{ display: "inline-flex", alignItems: "center", gap: 5 }}>esta semana · <i style={{ width: 24, height: 7, borderRadius: 3, background: "linear-gradient(90deg, color-mix(in srgb, var(--accent) 12%, transparent), var(--accent))" }}></i> + reuniones</span>
      </div>
      <span style={{ font: "var(--type-caption)", color: "var(--text-secondary)" }}>✦ Martes es tu día más denso; los viernes casi no tienes reuniones — buen día para trabajo profundo.</span>
    </div>
  );
}

function PVPeople() {
  const rows = [
    { name: "Alejo", meta: "2 reuniones · 58 min", them: 55, you: 45 },
    { name: "Cesare", meta: "2 reuniones · 41 min", them: 70, you: 30 },
    { name: "Daniel", meta: "2 reuniones · 39 min", them: 35, you: 65 },
  ];
  return (
    <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 10, padding: 16, borderRadius: 12, background: "var(--surface-card-soft)" }}>
      <span style={{ font: "var(--type-headline)", color: "var(--text-primary)" }}>Con quién y cómo hablas</span>
      {rows.map((p) => (
        <div key={p.name} style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <span style={{ width: 26, height: 26, borderRadius: 999, background: "var(--accent-tint-14)", color: "var(--accent)", display: "inline-flex", alignItems: "center", justifyContent: "center", font: "600 11px/1 var(--font-app)", flexShrink: 0 }}>{p.name[0]}</span>
          <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 3 }}>
            <div style={{ display: "flex", justifyContent: "space-between", font: "var(--type-body)", color: "var(--text-primary)" }}>
              <span>{p.name}</span>
              <span style={{ font: "var(--type-caption)", fontVariantNumeric: "tabular-nums", color: "var(--text-secondary)" }}>{p.meta}</span>
            </div>
            <div style={{ height: 5, borderRadius: 99, background: "var(--fill-quaternary)", overflow: "hidden", display: "flex" }}>
              <span style={{ width: `${p.them}%`, background: "var(--voice-1)" }}></span>
              <span style={{ width: `${p.you}%`, background: "var(--voice-me)" }}></span>
            </div>
          </div>
        </div>
      ))}
      <span style={{ font: "var(--type-caption)", color: "var(--text-tertiary)" }}>violeta = hablan ellos · ámbar = hablas tú. Con Daniel dominas el 65% — ✦ ¿1:1 con más escucha?</span>
    </div>
  );
}

function PVInsights() {
  return (
    <div style={{ flex: 1, overflowY: "auto" }}>
      <div style={{ display: "flex", flexDirection: "column", gap: 16, padding: 24, maxWidth: 860 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 12 }}>
          <span style={{ font: "var(--type-large-title)", color: "var(--text-primary)" }}>Insights</span>
          <span style={{ display: "flex", borderRadius: 8, overflow: "hidden", font: "500 11px/1 var(--font-app)", background: "var(--fill-quaternary)" }}>
            <span style={{ padding: "6px 12px", background: "var(--accent)", color: "var(--on-accent)" }}>Semana</span>
            <span style={{ padding: "6px 12px", color: "var(--text-secondary)" }}>Mes</span>
            <span style={{ padding: "6px 12px", color: "var(--text-secondary)" }}>Año</span>
          </span>
          <span style={{ flex: 1 }}></span>
          <span style={{ font: "var(--type-caption)", color: "var(--text-tertiary)" }}>🔒 Calculado en tu Mac — nada sale de él.</span>
        </div>
        <PVIndicators />
        <PVFindings />
        <div style={{ display: "flex", gap: 14, alignItems: "stretch" }}>
          <PVRhythm />
          <PVPeople />
        </div>
      </div>
    </div>
  );
}

window.PVInsights = PVInsights;
