// Settings — recreation of the redesigned Settings (exploration 2a):
// left nav with search + "all local" seal, an Intelligence pane with the
// honest Apple-Intelligence recommendation, grouped rows, and the original
// "Panel de tus datos" privacy ledger. Full 1000×780 window.
const { SFIcon } = window.PortavozDesignSystem_fd5562;

const PV_SET_NAV = [
  { icon: "globe", label: "General e idioma", sub: "Idioma sistema · English/Español · barra de menú" },
  { icon: "mic", label: "Audio y dictado", sub: "Cancelación de eco · dicta en cualquier lugar · ⌥⌘D" },
  { icon: "sparkles", label: "Inteligencia", sub: "Motor de resúmenes · refine Whisper · vocabulario · 13", active: true },
  { icon: "person.wave.2", label: "Mi voz y Companion", sub: "Voz enrolada 7 jul · tu nombre «Johnny»" },
  { icon: "calendar.badge.clock", label: "Agenda y automatización", sub: "Aviso 5 min antes · Atajo al terminar · títulos {date}" },
  { icon: "link", label: "Integraciones", sub: "BYOK OpenAI-compatible · GitHub gists · MCP local" },
  { icon: "lock.shield", label: "Tus datos", sub: "Exportar Markdown · carpeta de grabaciones · papelera" },
];

function PVSetRow({ children }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 12, padding: "13px 16px", background: "rgba(255,255,255,0.05)" }}>{children}</div>
  );
}

function PVSettings() {
  const [active, setActive] = React.useState(2);
  return (
    <div data-theme="dark" data-screen-label="Portavoz Settings" style={{
      width: 1000, height: 780, display: "flex", background: "var(--bg-window)",
      color: "rgba(255,255,255,0.87)", fontFamily: "var(--font-app)", overflow: "hidden",
    }}>
      <div style={{ width: 224, flexShrink: 0, display: "flex", flexDirection: "column", background: "rgba(14,17,32,0.55)", borderRight: "0.5px solid rgba(255,255,255,0.09)", padding: "12px 10px" }}>
        <div style={{ display: "flex", gap: 8, padding: "2px 4px 12px" }}>
          <span style={{ width: 11, height: 11, borderRadius: 999, background: "#ff5f57" }}></span>
          <span style={{ width: 11, height: 11, borderRadius: 999, background: "#febc2e" }}></span>
          <span style={{ width: 11, height: 11, borderRadius: 999, background: "#28c840" }}></span>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 7, background: "rgba(255,255,255,0.07)", borderRadius: 7, padding: "7px 9px", marginBottom: 12 }}>
          <SFIcon name="magnifyingglass" size={12} color="rgba(255,255,255,0.4)" />
          <input placeholder="Buscar un ajuste…" style={{ flex: 1, minWidth: 0, font: "400 12px/1 var(--font-app)", color: "rgba(255,255,255,0.87)", background: "none", border: "none", outline: "none" }} />
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
          {PV_SET_NAV.map((n, i) => {
            const on = i === active;
            return (
              <button key={n.label} type="button" onClick={() => setActive(i)} style={{
                display: "flex", flexDirection: "column", gap: 2, padding: "7px 10px", borderRadius: 7,
                border: "none", cursor: "pointer", textAlign: "left",
                background: on ? "linear-gradient(135deg, rgba(109,92,230,0.9), rgba(82,38,191,0.9))" : "transparent",
                color: on ? "#fff" : "rgba(255,255,255,0.87)",
              }}>
                <span style={{ display: "flex", alignItems: "center", gap: 8, font: on ? "500 13px/1.2 var(--font-app)" : "400 13px/1.2 var(--font-app)" }}>
                  <SFIcon name={n.icon} size={13} color={on ? "#fff" : "rgba(255,255,255,0.7)"} />{n.label}
                </span>
                <span style={{ font: "400 9.5px/1.3 var(--font-app)", color: on ? "rgba(255,255,255,0.65)" : "rgba(255,255,255,0.4)", paddingLeft: 21 }}>{n.sub}</span>
              </button>
            );
          })}
        </div>
        <div style={{ marginTop: "auto", padding: "12px 10px", borderRadius: 10, background: "rgba(48,209,88,0.08)", border: "1px solid rgba(48,209,88,0.2)" }}>
          <span style={{ display: "flex", alignItems: "center", gap: 5, font: "600 11px/1.3 var(--font-app)", color: "#30d158", marginBottom: 4 }}><SFIcon name="lock.shield" size={12} color="#30d158" />Todo local</span>
          <span style={{ font: "400 10px/1.5 var(--font-app)", color: "rgba(255,255,255,0.5)" }}>0 bytes enviados a la nube esta semana. Verifícalo en «Tus datos».</span>
        </div>
      </div>

      <div style={{ flex: 1, overflowY: "auto", display: "flex", flexDirection: "column", gap: 14, padding: "22px 26px" }}>
        <span style={{ display: "flex", alignItems: "center", gap: 8, font: "700 22px/1.2 var(--font-app)" }}><SFIcon name="sparkles" size={19} color="var(--accent)" />Inteligencia</span>

        <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "16px 18px", borderRadius: 14, background: "linear-gradient(135deg, rgba(109,92,230,0.25), rgba(82,38,191,0.15))", border: "1px solid rgba(109,92,230,0.4)" }}>
          <div style={{ width: 40, height: 40, borderRadius: 999, background: "rgba(109,92,230,0.3)", display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>
            <SFIcon name="wand.and.stars" size={20} color="#cfc9ff" />
          </div>
          <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 2 }}>
            <span style={{ font: "600 13px/1.3 var(--font-app)" }}>Tu Mac tiene Apple Intelligence — resumen en el Neural Engine, gratis y sin descargas.</span>
            <span style={{ font: "400 11px/1.4 var(--font-app)", color: "rgba(255,255,255,0.55)" }}>Recomendación medida en TU hardware, no una promesa.</span>
          </div>
          <button type="button" style={{ font: "600 12px/1 var(--font-app)", color: "#fff", background: "#5e5ce6", border: "none", borderRadius: 999, padding: "9px 16px", cursor: "pointer" }}>Aplicar</button>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 1, borderRadius: 12, overflow: "hidden" }}>
          <PVSetRow>
            <span style={{ flex: 1, font: "400 13px/1.4 var(--font-app)" }}>Generar resúmenes con</span>
            <span style={{ display: "flex", borderRadius: 8, overflow: "hidden", font: "500 11px/1 var(--font-app)", background: "rgba(255,255,255,0.08)" }}>
              <span style={{ padding: "7px 12px", background: "#5e5ce6", color: "#fff" }}>Apple</span>
              <span style={{ padding: "7px 12px", color: "rgba(255,255,255,0.6)" }}>Ollama</span>
              <span style={{ padding: "7px 12px", color: "rgba(255,255,255,0.6)" }}>Integrado</span>
            </span>
          </PVSetRow>
          <PVSetRow>
            <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 2 }}>
              <span style={{ font: "400 13px/1.4 var(--font-app)" }}>Modelo de refine (Whisper)</span>
              <span style={{ font: "400 10px/1.4 var(--font-app)", color: "rgba(255,255,255,0.45)" }}>Turbo · 1.64 GB descargado · 23–42× tiempo real</span>
            </div>
            <span style={{ font: "500 11px/1 var(--font-mono)", color: "#30d158" }}>● listo</span>
          </PVSetRow>
          <PVSetRow>
            <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 2 }}>
              <span style={{ font: "400 13px/1.4 var(--font-app)" }}>Vocabulario · 13 términos</span>
              <span style={{ font: "400 10px/1.4 var(--font-app)", color: "rgba(255,255,255,0.45)" }}>keycloak · LVGT · trinity · Alejo · +9 — ✦ sugiere desde tus reuniones</span>
            </div>
            <span style={{ display: "flex", alignItems: "center", gap: 4, font: "400 12px/1 var(--font-app)", color: "#9d8cff", cursor: "pointer" }}><SFIcon name="sparkles" size={11} color="var(--chip-ai-spark)" />8 sugeridos</span>
          </PVSetRow>
          <PVSetRow>
            <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 2 }}>
              <span style={{ font: "400 13px/1.4 var(--font-app)" }}>Cancelación de eco</span>
              <span style={{ font: "400 10px/1.4 var(--font-app)", color: "rgba(255,255,255,0.45)" }}>recomendada con parlantes — con AirPods suele sonar mejor apagada</span>
            </div>
            <span style={{ width: 34, height: 20, borderRadius: 999, background: "#30d158", position: "relative", display: "inline-block" }}><i style={{ position: "absolute", right: 2, top: 2, width: 16, height: 16, borderRadius: 999, background: "#fff" }}></i></span>
          </PVSetRow>
          <PVSetRow>
            <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 2 }}>
              <span style={{ font: "400 13px/1.4 var(--font-app)" }}>Plantilla de títulos</span>
              <span style={{ font: "400 10px/1.4 var(--font-app)", color: "rgba(255,255,255,0.45)" }}>vista previa: 2026-07-11 16.04 Reunión — chips {"{date} {time} {seq} {weekday}"}</span>
            </div>
            <span style={{ font: "500 11px/1 var(--font-mono)", color: "rgba(255,255,255,0.6)", background: "rgba(255,255,255,0.08)", borderRadius: 6, padding: "6px 10px" }}>{"{date} {time} Reunión"}</span>
          </PVSetRow>
        </div>

        <span style={{ font: "600 10px/1 var(--font-app)", letterSpacing: "0.08em", textTransform: "uppercase", color: "rgba(255,255,255,0.35)", marginTop: 4 }}>Panel de tus datos — el ledger de privacidad</span>
        <div style={{ display: "flex", gap: 10 }}>
          {[["2.4 GB", "audio en tu disco"], ["128", "reuniones en SQLite tuyo"], ["0 B", "enviados a la red · 7 días", "#30d158"], ["1", "voz enrolada · cifrada aquí"]].map(([v, l, c]) => (
            <div key={l} style={{ flex: 1, padding: "13px 14px", borderRadius: 12, background: "rgba(255,255,255,0.05)", display: "flex", flexDirection: "column", gap: 2 }}>
              <span style={{ font: "700 17px/1.2 var(--font-app)", fontVariantNumeric: "tabular-nums", color: c || "#fff" }}>{v}</span>
              <span style={{ font: "400 10px/1.4 var(--font-app)", color: "rgba(255,255,255,0.5)" }}>{l}</span>
            </div>
          ))}
        </div>
        <span style={{ font: "400 11px/1.5 var(--font-app)", color: "rgba(255,255,255,0.4)" }}>Cada ajuste sensible enlaza aquí: ver qué existe, dónde vive, y exportarlo o borrarlo. «Tu historial jamás es rehén» hecho interfaz.</span>
      </div>
    </div>
  );
}

window.PVSettings = PVSettings;
