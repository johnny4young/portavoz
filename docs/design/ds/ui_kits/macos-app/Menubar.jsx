// Menu bar — recreation of the rich menu-bar panel (exploration 2b).
// The bar icon IS a live mini-waveform (amber peak); the dropdown carries
// status, quick actions, the next meeting, and recents. Original idea:
// the icon breathes red while recording, indigo while dictating.
const { SFIcon } = window.PortavozDesignSystem_fd5562;

function PVMiniWave({ bars, height = 20, w = 3.5 }) {
  return (
    <span style={{ display: "flex", alignItems: "flex-end", gap: 2, height }}>
      {bars.map((b, i) => (
        <i key={i} style={{ width: w, height: `${b.h}%`, borderRadius: 99, background: b.c }}></i>
      ))}
    </span>
  );
}

function PVQuick({ icon, label, tint, ink }) {
  return (
    <button type="button" style={{
      display: "flex", flexDirection: "column", alignItems: "center", gap: 5, padding: "11px 6px",
      borderRadius: 11, border: "none", cursor: "pointer", background: tint, color: ink, font: "600 11px/1 var(--font-app)",
    }}>
      <SFIcon name={icon} size={15} color={ink} />{label}
    </button>
  );
}

function PVMenubar() {
  const barWave = [
    { h: 40, c: "#fff" }, { h: 75, c: "#fff" }, { h: 100, c: "var(--voice-me)" }, { h: 55, c: "#fff" },
  ];
  const panelWave = [
    { h: 35, c: "rgba(255,255,255,0.5)" }, { h: 65, c: "rgba(255,255,255,0.7)" }, { h: 100, c: "var(--voice-me)" }, { h: 50, c: "rgba(255,255,255,0.6)" },
  ];
  return (
    <div data-theme="dark" data-screen-label="Portavoz menu bar" style={{
      width: 560, padding: "0 0 30px", borderRadius: 12, fontFamily: "var(--font-app)",
      background: "linear-gradient(180deg, #3d3358, #26232e 30%, #1c1a22)",
      boxShadow: "0 0 0 0.5px rgba(255,255,255,0.14), 0 30px 70px rgba(0,0,0,0.55)",
      display: "flex", flexDirection: "column", alignItems: "center",
    }}>
      <div style={{ width: "100%", display: "flex", justifyContent: "flex-end", alignItems: "center", gap: 18, padding: "8px 20px", color: "rgba(255,255,255,0.85)", font: "500 13px/1 var(--font-app)" }}>
        <span style={{ padding: "2px 6px", borderRadius: 5, background: "rgba(255,255,255,0.18)" }}><PVMiniWave bars={barWave} height={14} w={2.5} /></span>
        <span style={{ fontVariantNumeric: "tabular-nums" }}>⏱ in 1d 18h</span>
        <span style={{ fontVariantNumeric: "tabular-nums" }}>16:04</span>
      </div>

      <div style={{ width: 340, marginTop: 6, borderRadius: 16, overflow: "hidden", background: "rgba(30,30,36,0.92)", backdropFilter: "blur(30px)", border: "0.5px solid rgba(255,255,255,0.14)", boxShadow: "0 18px 50px rgba(0,0,0,0.5)", color: "rgba(255,255,255,0.88)" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "14px 16px", background: "radial-gradient(280px 120px at 85% -30%, rgba(82,38,191,0.5), transparent 70%)" }}>
          <PVMiniWave bars={panelWave} />
          <div style={{ display: "flex", flexDirection: "column", gap: 1, flex: 1 }}>
            <span style={{ font: "600 12px/1.2 var(--font-app)" }}>Portavoz en reposo</span>
            <span style={{ display: "flex", alignItems: "center", gap: 4, font: "400 10px/1.3 var(--font-app)", color: "#30d158" }}><SFIcon name="lock.shield" size={10} color="#30d158" />100% local · 0 B a la red hoy</span>
          </div>
        </div>

        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 8, padding: "4px 14px 12px" }}>
          <PVQuick icon="record.circle" label="Grabar" tint="linear-gradient(135deg, rgba(255,69,58,0.25), rgba(255,69,58,0.12))" ink="#ff6961" />
          <PVQuick icon="waveform" label="Dictar ⌥⌘D" tint="rgba(109,92,230,0.2)" ink="#cfc9ff" />
          <PVQuick icon="bubble.left.and.text.bubble.right" label="Preguntar" tint="rgba(255,255,255,0.08)" ink="rgba(255,255,255,0.85)" />
        </div>

        <div style={{ margin: "0 14px 10px", padding: "11px 13px", borderRadius: 12, background: "rgba(253,191,71,0.09)", border: "1px solid rgba(253,191,71,0.25)" }}>
          <span style={{ display: "block", font: "600 10px/1 var(--font-app)", letterSpacing: "0.07em", textTransform: "uppercase", color: "var(--brand-amber)", marginBottom: 5 }}>Próxima reunión · mañana 10:00</span>
          <span style={{ display: "block", font: "500 13px/1.3 var(--font-app)", marginBottom: 6 }}>Retro sprint 15</span>
          <div style={{ display: "flex", gap: 6 }}>
            <span style={{ display: "inline-flex", alignItems: "center", gap: 4, font: "600 10px/1 var(--font-app)", color: "#cfc9ff", background: "rgba(109,92,230,0.25)", borderRadius: 999, padding: "5px 9px", cursor: "pointer" }}><SFIcon name="sparkles" size={9} color="var(--chip-ai-spark)" />Ver brief</span>
            <span style={{ font: "600 10px/1 var(--font-app)", color: "rgba(255,255,255,0.7)", background: "rgba(255,255,255,0.08)", borderRadius: 999, padding: "5px 9px", cursor: "pointer" }}>Grabar al empezar</span>
          </div>
        </div>

        <div style={{ padding: "0 16px 6px" }}>
          <span style={{ font: "600 10px/1 var(--font-app)", letterSpacing: "0.07em", textTransform: "uppercase", color: "rgba(255,255,255,0.35)" }}>Recientes</span>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", padding: "7px 0", font: "400 12.5px/1.3 var(--font-app)" }}>
            <span>2026-07-10 Sprint Demo · Zephyr</span><span style={{ font: "400 10px/1 var(--font-mono)", color: "rgba(255,255,255,0.4)" }}>hoy · ✦ 3 pendientes</span>
          </div>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", padding: "7px 0", font: "400 12.5px/1.3 var(--font-app)" }}>
            <span>2026-07-09 Sync semanal QVTL</span><span style={{ font: "400 10px/1 var(--font-mono)", color: "rgba(255,255,255,0.4)" }}>ayer</span>
          </div>
        </div>

        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "10px 16px", borderTop: "0.5px solid rgba(255,255,255,0.1)", font: "400 12px/1 var(--font-app)", color: "rgba(255,255,255,0.6)" }}>
          <span style={{ cursor: "pointer" }}>Abrir Portavoz</span><span style={{ cursor: "pointer" }}>Ajustes ⌘,</span><span style={{ cursor: "pointer" }}>Salir</span>
        </div>
      </div>

      <span style={{ marginTop: 18, font: "400 11px/1.6 var(--font-app)", color: "rgba(255,255,255,0.45)", maxWidth: 420, textAlign: "center" }}>El icono de la barra ES un mini-waveform vivo — reposo estático, rojo al grabar, indigo al dictar. El «in 1d 18h» de la próxima reunión vive al lado, clicable.</span>
    </div>
  );
}

window.PVMenubar = PVMenubar;
