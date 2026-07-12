// Meeting detail — consolidated with the canonical Aurora template
// (templates/macos-app): radial header with Fraunces title, ✦ chips,
// summary tabs + ↗ citations, voice-colored health, lyrics transcript,
// Spotify-style player, and the Capítulos ✦ rail.
const { SpeakerPill, SuggestionChip } = window.PortavozDesignSystem_fd5562;
const pvDetail = window.PV_DATA;

const PV_TAB = (active) => ({
  font: "600 10px/1 var(--font-app)", padding: "5px 10px", borderRadius: 999,
  background: active ? "#6d5ce6" : "rgba(255,255,255,0.08)",
  color: active ? "#fff" : "rgba(255,255,255,0.6)", cursor: "pointer",
});

function PVMeetingDetail({ todos, onToggleTodo }) {
  const [titleApplied, setTitleApplied] = React.useState(false);
  const [named, setNamed] = React.useState(false);
  const title = titleApplied ? "Zephyr beta demo and sprint decisions" : "Sprint Demo · Zephyr";

  return (
    <div style={{ flex: 1, overflowY: "auto", display: "flex", flexDirection: "column", minWidth: 0 }}>
      <div style={{ padding: "22px 30px 16px", background: "var(--aurora-header)", borderBottom: "0.5px solid rgba(255,255,255,0.08)" }}>
        <div style={{ display: "flex", alignItems: "flex-end", gap: 3, height: 28, marginBottom: 10 }}>
          {[["30%", "rgba(255,255,255,0.25)"], ["55%", "rgba(255,255,255,0.3)"], ["80%", "rgba(255,255,255,0.4)"], ["100%", "var(--voice-me)"], ["62%", "rgba(255,255,255,0.35)"], ["40%", "rgba(255,255,255,0.28)"]].map(([h, c], i) => (
            <span key={i} style={{ width: 5, height: h, borderRadius: 99, background: c }}></span>
          ))}
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
          <span style={{ fontFamily: "var(--font-display)", fontVariationSettings: "'SOFT' 50", fontSize: 25, fontWeight: 560 }}>{title}</span>
          {!titleApplied ? (
            <SuggestionChip kind="ai" onApply={() => setTitleApplied(true)}
              helpText="Título sugerido desde el resumen — nada cambia si no aceptas">
              ¿«Zephyr beta demo and sprint decisions»?
            </SuggestionChip>
          ) : null}
        </div>
        <div style={{ display: "flex", gap: 14, marginTop: 7, font: "400 12px/1 var(--font-app)", color: "rgba(255,255,255,0.5)", fontVariantNumeric: "tabular-nums" }}>
          <span>10 julio 2026 · 10:00</span><span>42 min</span><span>9 segmentos</span>
          <span style={{ color: "#30d158" }}>resumen local · 3.8 s</span>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 11, flexWrap: "wrap" }}>
          {pvDetail.speakers.map((s) => (
            <SpeakerPill key={s.name} name={s.name === "S3" && named ? "Priya" : s.name} me={s.me}
              voice={s.name === "S3" ? (named ? 3 : undefined) : s.voice} />
          ))}
          {!named ? (
            <SuggestionChip kind="ai" onApply={() => setNamed(true)}
              helpText="Evidencia: «Priya, ¿nos das el estado?» a las 05:22">¿S3 → Priya?</SuggestionChip>
          ) : (
            <SuggestionChip kind="offer" onDismiss={() => {}}>¿Recordar la voz de Priya?</SuggestionChip>
          )}
        </div>
      </div>

      <div style={{ flex: 1, display: "flex", gap: 20, padding: "18px 30px", overflow: "hidden" }}>
        <div style={{ flex: 1.3, display: "flex", flexDirection: "column", gap: 12, minWidth: 0 }}>
          <div style={{ display: "flex", flexDirection: "column", gap: 8, padding: 16, background: "rgba(255,255,255,0.045)", borderRadius: "var(--radius-panel)" }}>
            <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
              <span style={PV_TAB(true)}>Resumen</span>
              <span style={PV_TAB(false)}>Decisiones · 3</span>
              <span style={PV_TAB(false)}>Preguntas · 1</span>
              <span style={PV_TAB(false)}>Pendientes · {todos.filter((t) => t.done).length}/{todos.length}</span>
              <span style={{ flex: 1 }}></span>
              <span style={{ font: "400 10px/1 var(--font-mono)", color: "rgba(255,255,255,0.4)" }}>v1 · es</span>
            </div>
            <p style={{ font: "400 13px/1.55 var(--font-app)", margin: 0, color: "rgba(255,255,255,0.8)" }}>{pvDetail.summaryLede}</p>
            <div style={{ display: "flex", gap: 8, font: "400 13px/1.5 var(--font-app)" }}>
              <span style={{ color: "rgba(255,255,255,0.3)" }}>·</span>
              <span>La beta sale el lunes; Marta lidera la demo con el cliente.</span>
              <span style={{ font: "400 10px/1.8 var(--font-mono)", color: "#9d8cff", cursor: "pointer" }}>↗ 06:18</span>
            </div>
            <div style={{ display: "flex", gap: 8, font: "400 13px/1.5 var(--font-app)" }}>
              <span style={{ color: "var(--voice-me)" }}>▸</span>
              <span style={{ fontWeight: 600 }}>Congelar el scope del sprint 15.</span>
              <span style={{ font: "400 10px/1.8 var(--font-mono)", color: "rgba(255,255,255,0.35)" }}>tu nota · ↗ 04:36</span>
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 5 }}>
              {todos.map((t) => (
                <label key={t.id} style={{ display: "flex", gap: 8, alignItems: "flex-start", font: "400 13px/1.5 var(--font-app)", cursor: "pointer" }}>
                  <input type="checkbox" checked={!!t.done} onChange={() => onToggleTodo(t.id)} style={{ accentColor: "#6d5ce6", marginTop: 3 }} />
                  <span style={{ textDecoration: t.done ? "line-through" : "none", opacity: t.done ? 0.5 : 1 }}>{t.text}</span>
                </label>
              ))}
            </div>
          </div>

          <div style={{ position: "relative", display: "flex", flexDirection: "column", gap: 8, flex: 1, overflow: "hidden", padding: "2px 0" }}>
            <div style={{ display: "flex", alignItems: "baseline", gap: 10 }}>
              <span style={{ font: "600 13px/1 var(--font-app)" }}>Transcript</span>
              <span style={{ font: "400 10px/1 var(--font-app)", color: "rgba(255,255,255,0.35)" }}>lyrics tipo Spotify — sube solo, blur en extremos, click = saltar al audio</span>
            </div>
            <div style={{ display: "flex", alignItems: "baseline", gap: 9, padding: "3px 10px", opacity: 0.35, filter: "blur(1.2px)" }}>
              <span style={{ font: "400 10px/1.4 var(--font-mono)", color: "rgba(255,255,255,0.3)" }}>00:12</span>
              <SpeakerPill name="Marta" voice={1} editable={false} />
              <span style={{ font: "400 13px/1.5 var(--font-app)", color: "rgba(255,255,255,0.75)" }}>Arranquemos con el estado de Zephyr: el cluster ya corre la build 214…</span>
            </div>
            <div style={{ display: "flex", alignItems: "baseline", gap: 9, padding: "8px 12px", borderRadius: 10, background: "linear-gradient(90deg, color-mix(in srgb, var(--voice-me) 14%, transparent), transparent 85%)", boxShadow: "inset 2px 0 0 var(--voice-me)" }}>
              <span style={{ font: "400 10px/1.6 var(--font-mono)", color: "var(--voice-me)" }}>00:54</span>
              <SpeakerPill name="Me" me editable={false} />
              <span style={{ font: "500 14px/1.5 var(--font-app)" }}>Perfecto. ¿Cerramos entonces el <span style={{ color: "#9d8cff" }}>bug del device-ID duplicado</span> en QVTL?</span>
            </div>
            <div style={{ display: "flex", alignItems: "baseline", gap: 9, padding: "3px 10px", opacity: 0.35, filter: "blur(1.2px)" }}>
              <span style={{ font: "400 10px/1.4 var(--font-mono)", color: "rgba(255,255,255,0.3)" }}>01:24</span>
              <SpeakerPill name="Ilarion" voice={2} editable={false} />
              <span style={{ font: "400 13px/1.5 var(--font-app)", color: "rgba(255,255,255,0.75)" }}>Sí, era el cache del provisioning. El fix está en main…</span>
            </div>
          </div>

          <div style={{ display: "flex", alignItems: "center", gap: 12, padding: "11px 16px", background: "rgba(14,17,32,0.75)", borderRadius: 999, boxShadow: "0 0 0 0.5px rgba(255,255,255,0.12)" }}>
            <span style={{ fontSize: 14, cursor: "pointer" }}>▶</span>
            <div style={{ display: "flex", alignItems: "flex-end", gap: 2, height: 20, flex: 1 }}>
              {[["35%", "var(--voice-1)"], ["70%", "var(--voice-1)"], ["45%", "var(--voice-1)"], ["90%", "var(--voice-me)"], ["60%", "var(--voice-me)"], ["38%", "var(--voice-2)"], ["75%", "rgba(255,255,255,0.3)"], ["50%", "rgba(255,255,255,0.25)"], ["28%", "rgba(255,255,255,0.2)"], ["64%", "rgba(255,255,255,0.28)"], ["42%", "rgba(255,255,255,0.22)"], ["80%", "rgba(255,255,255,0.3)"]].map(([h, c], i) => (
                <span key={i} style={{ width: 3, height: h, borderRadius: 99, background: c }}></span>
              ))}
            </div>
            <span style={{ font: "600 10px/1 var(--font-app)", color: "#cfc9ff", background: "rgba(109,92,230,0.22)", borderRadius: 999, padding: "5px 10px", cursor: "pointer" }}>⏭ Silencios</span>
            <span style={{ font: "600 10px/1 var(--font-app)", color: "var(--voice-me)", background: "color-mix(in srgb, var(--voice-me) 18%, transparent)", borderRadius: 999, padding: "5px 10px", cursor: "pointer" }}>solo mi voz</span>
            <span style={{ font: "500 11px/1 var(--font-mono)", fontVariantNumeric: "tabular-nums", color: "rgba(255,255,255,0.6)" }}>00:54 / 42:10</span>
          </div>
        </div>

        <div style={{ width: 244, flexShrink: 0, display: "flex", flexDirection: "column", gap: 11 }}>
          <span style={{ font: "600 10px/1 var(--font-app)", letterSpacing: "0.08em", textTransform: "uppercase", color: "rgba(255,255,255,0.35)" }}>Salud de la reunión</span>
          <div style={{ display: "flex", flexDirection: "column", gap: 8, padding: 14, background: "rgba(255,255,255,0.045)", borderRadius: "var(--radius-panel)" }}>
            {pvDetail.health.map((h) => {
              const hue = h.voice === "me" ? "var(--voice-me)" : h.voice ? `var(--voice-${h.voice})` : "var(--pill-neutral)";
              return (
                <div key={h.name} style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <span style={{ font: "600 11px/1 var(--font-app)", width: 42, color: h.voice ? hue : "rgba(255,255,255,0.6)", flexShrink: 0 }}>{h.name === "Me" ? "Yo" : h.name}</span>
                  <div style={{ flex: 1, height: 6, borderRadius: 99, background: "rgba(255,255,255,0.08)", overflow: "hidden" }}>
                    <span style={{ display: "block", width: `${h.share * 100}%`, height: "100%", borderRadius: 99, background: hue }}></span>
                  </div>
                  <span style={{ font: "400 10px/1 var(--font-mono)", color: "rgba(255,255,255,0.45)" }}>{h.pct}</span>
                </div>
              );
            })}
            <span style={{ font: "400 10px/1.5 var(--font-app)", color: "rgba(255,255,255,0.4)" }}>2 preguntas · 1 interrupción — calculado en tu Mac.</span>
          </div>
          <span style={{ font: "600 10px/1 var(--font-app)", letterSpacing: "0.08em", textTransform: "uppercase", color: "rgba(255,255,255,0.35)" }}>Capítulos ✦</span>
          <div style={{ display: "flex", flexDirection: "column", gap: 7 }}>
            {[["00:00", "Estado de Zephyr · build 214", false], ["04:36", "Scope sprint 15 · 2 decisiones", true], ["06:18", "Decisión: la beta sale el lunes", false]].map(([t, label, hot]) => (
              <button key={t} type="button" style={{
                display: "flex", justifyContent: "flex-start", textAlign: "left", alignItems: "baseline", gap: 8,
                color: "rgba(255,255,255,0.85)", background: "rgba(255,255,255,0.06)", border: "none",
                padding: "9px 11px", borderRadius: 10, font: "400 11px/1.4 var(--font-app)", cursor: "pointer",
              }}>
                <span style={{ font: "500 10px/1.5 var(--font-mono)", color: hot ? "var(--voice-me)" : "rgba(255,255,255,0.4)" }}>{t}</span>
                {label}
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

window.PVMeetingDetail = PVMeetingDetail;
