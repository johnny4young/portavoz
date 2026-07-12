// Dictation — a SINGLE floating panel that shares the Recording HUD's
// material/blur (FloatingPanel) and morphs between states: dictating →
// inserted (no trace) → warning. Unified with the HUD surface language.
const { FloatingPanel, MicMeter, SFIcon } = window.PortavozDesignSystem_fd5562;

const PV_DICT_STATES = [
  { id: "dictating", label: "Dictando" },
  { id: "inserted", label: "Insertado" },
  { id: "warning", label: "Aviso" },
];

function PVDictation() {
  const [state, setState] = React.useState("dictating");
  const [level, setLevel] = React.useState(0.5);
  React.useEffect(() => {
    const id = setInterval(() => setLevel(0.3 + Math.random() * 0.5), 180);
    return () => clearInterval(id);
  }, []);
  const warning = state === "warning";

  return (
    <div data-screen-label="Portavoz dictation" style={{
      width: 640, padding: 44, borderRadius: 12, fontFamily: "var(--font-app)",
      background: "linear-gradient(160deg, #e8e6f2, #d8d5e6)",
      display: "flex", flexDirection: "column", gap: 20, alignItems: "center",
      boxShadow: "0 0 0 0.5px rgba(0,0,0,0.12), 0 30px 70px rgba(0,0,0,0.35)",
    }}>
      <FloatingPanel variant="dictation">
        {state === "inserted" ? (
          <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
            <span style={{ width: 20, height: 20, borderRadius: 999, background: "var(--success)", display: "inline-flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>
              <SFIcon name="checkmark" size={11} color="#fff" />
            </span>
            <div style={{ display: "flex", flexDirection: "column", gap: 1, flex: 1, minWidth: 0 }}>
              <span style={{ font: "500 13px/1.35 var(--font-app)", color: "var(--text-primary)" }}>42 palabras insertadas en Notes.</span>
              <span style={{ font: "var(--type-caption)", color: "var(--text-secondary)" }}>Nada se guardó en Portavoz — el dictado jamás deja huella.</span>
            </div>
            <button type="button" onClick={() => setState("dictating")} style={{ font: "600 11px/1 var(--font-app)", color: "var(--text-secondary)", background: "var(--fill-quaternary)", border: "none", borderRadius: 999, padding: "6px 11px", cursor: "pointer" }}>Deshacer</button>
          </div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 7 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <SFIcon name={warning ? "waveform" : "waveform.and.mic"} size={15} color={warning ? "var(--warning)" : "var(--accent)"} />
              <span style={{ font: "600 12px/1 var(--font-app)", color: "var(--text-primary)" }}>Dictando</span>
              <span style={{ display: "inline-flex", alignItems: "center", gap: 4, font: "600 10px/1 var(--font-app)", color: "var(--accent)", background: "var(--accent-tint-14)", borderRadius: 999, padding: "4px 8px" }}>
                <SFIcon name="pencil" size={9} color="var(--accent)" />Notes · Reunión Q3
              </span>
              {warning ? (
                <span style={{ display: "inline-flex", alignItems: "center", gap: 4, font: "600 10px/1 var(--font-app)", color: "var(--warning)", background: "color-mix(in srgb, var(--warning) 18%, transparent)", borderRadius: 999, padding: "4px 8px" }}>
                  <SFIcon name="exclamationmark.bubble" size={9} color="var(--warning)" />mic bajo — ¿AirPods dormidos?
                </span>
              ) : (
                <span style={{ font: "600 10px/1 var(--font-app)", color: "var(--text-secondary)", background: "var(--fill-quaternary)", borderRadius: 999, padding: "4px 8px" }}>ES auto</span>
              )}
              <span style={{ flex: 1 }}></span>
              <MicMeter fraction={warning ? level * 0.3 : level} accent width={72} />
              <SFIcon name="xmark.circle.fill" size={15} color="var(--text-secondary)" />
            </div>
            <span style={{ font: "400 15px/1.5 var(--font-app)", color: "var(--text-primary)" }}>
              El presupuesto del Q3 cubre el crecimiento del lab<span style={{ color: "var(--text-tertiary)" }}> — coma, y las horas extra de transcripción…</span>
            </span>
            <span style={{ font: "var(--type-caption)", color: "var(--text-tertiary)" }}>
              {warning
                ? "Aviso honesto: no «error», sino la causa probable y qué hacer."
                : "El chip muestra la app y el campo destino reales — nunca dictas «a ciegas». Lo gris es volátil; se afirma al confirmarse. ⌥⌘D termina · esc cancela."}
            </span>
          </div>
        )}
      </FloatingPanel>

      <div style={{ display: "flex", gap: 6, padding: 4, borderRadius: 999, background: "rgba(0,0,0,0.06)" }}>
        {PV_DICT_STATES.map((s) => (
          <button key={s.id} type="button" onClick={() => setState(s.id)} style={{
            font: "600 11px/1 var(--font-app)", padding: "7px 14px", borderRadius: 999, border: "none", cursor: "pointer",
            background: state === s.id ? "rgba(255,255,255,0.9)" : "transparent",
            color: state === s.id ? "rgba(0,0,0,0.8)" : "rgba(0,0,0,0.5)",
            boxShadow: state === s.id ? "0 1px 3px rgba(0,0,0,0.15)" : "none",
          }}>{s.label}</button>
        ))}
      </div>
    </div>
  );
}

window.PVDictation = PVDictation;
