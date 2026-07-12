// Settings — nav-driven redesign whose content mirrors the REAL Portavoz
// Settings (see reference screenshot): system language, echo cancellation,
// dictate-anywhere, summary engine (Apple / Ollama / Integrado MLX), Whisper
// refine models, vocabulary chips, agenda, integrations (BYOK + GitHub),
// and "Tus datos" — the privacy ledger + recordings folder + title template.
const { SFIcon } = window.PortavozDesignSystem_fd5562;

const PV_SET_NAV = [
  { id: "general", icon: "globe", label: "General e idioma", sub: "Idioma sistema · English/Español · barra de menú" },
  { id: "audio", icon: "mic", label: "Audio y dictado", sub: "Cancelación de eco · dicta en cualquier lugar · ⌥⌘D" },
  { id: "intel", icon: "sparkles", label: "Inteligencia", sub: "Motor de resúmenes · refine Whisper · vocabulario · 13" },
  { id: "voice", icon: "person.wave.2", label: "Mi voz y Companion", sub: "Voz enrolada 7 jul · tu nombre «Johnny»" },
  { id: "agenda", icon: "calendar.badge.clock", label: "Agenda y automatización", sub: "Aviso 5 min antes · Atajo al terminar · títulos {date}" },
  { id: "integrations", icon: "link", label: "Integraciones", sub: "BYOK OpenAI-compatible · GitHub gists · MCP local" },
  { id: "data", icon: "lock.shield", label: "Tus datos", sub: "Exportar Markdown · carpeta de grabaciones · papelera" },
];

const PV_VOCAB = ["keycloak", "LVGT", "trinity", "processor", "messenger", "Alejo", "Jose", "Cesare", "Johnny", "Daniel", "Event bus", "Rei", "cox2m"];

// ---- primitives ------------------------------------------------------------
function PVRow({ title, sub, control, first }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 12, padding: "13px 16px", background: "rgba(255,255,255,0.05)", borderTop: first ? "none" : "0.5px solid rgba(255,255,255,0.06)" }}>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 2, minWidth: 0 }}>
        <span style={{ font: "400 13px/1.4 var(--font-app)" }}>{title}</span>
        {sub ? <span style={{ font: "400 10px/1.4 var(--font-app)", color: "rgba(255,255,255,0.45)" }}>{sub}</span> : null}
      </div>
      {control}
    </div>
  );
}
function PVGroup({ children }) {
  return <div style={{ display: "flex", flexDirection: "column", borderRadius: 12, overflow: "hidden" }}>{children}</div>;
}
function PVSecTitle({ children }) {
  return <span style={{ font: "600 10px/1 var(--font-app)", letterSpacing: "0.08em", textTransform: "uppercase", color: "rgba(255,255,255,0.35)", marginTop: 6 }}>{children}</span>;
}
function PVToggle({ on }) {
  return <span style={{ width: 34, height: 20, borderRadius: 999, background: on ? "var(--success)" : "rgba(255,255,255,0.18)", position: "relative", display: "inline-block", flexShrink: 0 }}><i style={{ position: "absolute", top: 2, [on ? "right" : "left"]: 2, width: 16, height: 16, borderRadius: 999, background: "#fff" }}></i></span>;
}
function PVSeg({ options, value, onPick }) {
  return (
    <span style={{ display: "flex", borderRadius: 8, overflow: "hidden", font: "500 11px/1 var(--font-app)", background: "rgba(255,255,255,0.08)", flexShrink: 0 }}>
      {options.map((o) => (
        <span key={o} onClick={() => onPick && onPick(o)} style={{ padding: "7px 12px", cursor: "pointer", background: o === value ? "#5e5ce6" : "transparent", color: o === value ? "#fff" : "rgba(255,255,255,0.6)" }}>{o}</span>
      ))}
    </span>
  );
}
function PVKeycap({ children }) {
  return <span style={{ font: "500 12px/1 var(--font-mono)", color: "rgba(255,255,255,0.75)", background: "rgba(255,255,255,0.08)", borderRadius: 6, padding: "6px 10px", flexShrink: 0 }}>{children}</span>;
}
function PVRadio({ on }) {
  return <span style={{ width: 15, height: 15, borderRadius: 999, border: on ? "4px solid #5e5ce6" : "1.5px solid rgba(255,255,255,0.35)", background: on ? "#fff" : "transparent", flexShrink: 0, boxSizing: "border-box" }}></span>;
}
function PVGhostBtn({ children, danger }) {
  return <button type="button" style={{ font: "600 11px/1 var(--font-app)", color: danger ? "var(--destructive)" : "rgba(255,255,255,0.8)", background: danger ? "rgba(255,69,58,0.12)" : "rgba(255,255,255,0.08)", border: "none", borderRadius: 8, padding: "7px 12px", cursor: "pointer", flexShrink: 0 }}>{children}</button>;
}

// ---- section panes ---------------------------------------------------------
function PVPaneGeneral() {
  const [lang, setLang] = React.useState("Español");
  return (
    <>
      <span style={{ font: "700 22px/1.2 var(--font-app)" }}>General e idioma</span>
      <PVGroup>
        <PVRow first title="Usar idioma del sistema" control={<PVToggle on={false} />} />
        <PVRow title="Idioma" control={<PVSeg options={["English", "Español"]} value={lang} onPick={setLang} />} />
      </PVGroup>
      <span style={{ font: "400 11px/1.5 var(--font-app)", color: "rgba(255,255,255,0.4)" }}>Cambia solo la interfaz de Portavoz. Los idiomas de transcripción y resumen siguen controlados por cada reunión.</span>
    </>
  );
}
function PVPaneAudio() {
  return (
    <>
      <span style={{ font: "700 22px/1.2 var(--font-app)" }}>Audio y dictado</span>
      <PVGroup>
        <PVRow first title="Cancelación de eco" sub="recomendada con parlantes — con AirPods suele sonar mejor apagada" control={<PVToggle on />} />
        <PVRow title="Dicta en cualquier lugar" sub="⌥⌘D en cualquier app; requiere permiso de Accesibilidad (macOS lo pide la primera vez)" control={<PVToggle on={false} />} />
        <PVRow title="Atajo de dictado" control={<PVKeycap>^⌥⌘</PVKeycap>} />
      </PVGroup>
      <span style={{ font: "400 11px/1.5 var(--font-app)", color: "rgba(255,255,255,0.4)" }}>Las palabras se escriben donde está tu cursor — jamás se guardan. Insertar texto requiere permiso de Accesibilidad.</span>
    </>
  );
}
function PVPaneIntel() {
  const [engine, setEngine] = React.useState("Integrado (MLX)");
  const [refine, setRefine] = React.useState("Turbo");
  return (
    <>
      <span style={{ display: "flex", alignItems: "center", gap: 8, font: "700 22px/1.2 var(--font-app)" }}><SFIcon name="sparkles" size={19} color="var(--accent)" />Inteligencia</span>

      <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "16px 18px", borderRadius: 14, background: "linear-gradient(135deg, rgba(109,92,230,0.25), rgba(82,38,191,0.15))", border: "1px solid rgba(109,92,230,0.4)" }}>
        <div style={{ width: 40, height: 40, borderRadius: 999, background: "rgba(109,92,230,0.3)", display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}><SFIcon name="wand.and.stars" size={20} color="#cfc9ff" /></div>
        <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 2 }}>
          <span style={{ font: "600 13px/1.3 var(--font-app)" }}>Tu Mac tiene Apple Intelligence — resumen en el Neural Engine, gratis y sin descargas.</span>
          <span style={{ font: "400 11px/1.4 var(--font-app)", color: "rgba(255,255,255,0.55)" }}>Recomendación medida en TU hardware, no una promesa.</span>
        </div>
        <button type="button" style={{ font: "600 12px/1 var(--font-app)", color: "#fff", background: "#5e5ce6", border: "none", borderRadius: 999, padding: "9px 16px", cursor: "pointer" }}>Aplicar</button>
      </div>

      <PVSecTitle>Motor de resúmenes</PVSecTitle>
      <PVGroup>
        {[["Apple", "Foundation Models — macOS 26 + Apple Intelligence"], ["Ollama (local)", "corre un modelo 100% local en tu Mac"], ["Integrado (MLX)", "modelo 4B embebido — descarga verificada de 3 GB, sin instalar nada"]].map(([o, sub], i) => (
          <PVRow key={o} first={i === 0} title={o} sub={sub} control={<PVRadio on={engine === o} />} />
        ))}
        <PVRow title="Qwen3.5 4B" sub="descargado · 3 GB" control={<PVGhostBtn danger>Eliminar</PVGhostBtn>} />
      </PVGroup>

      <PVSecTitle>Modelo de refine (Whisper large-v3)</PVSecTitle>
      <PVGroup>
        <PVRow first title="Turbo — mejor calidad" sub="Downloaded · 1,64 GB · 23–42× tiempo real" control={<PVRadio on={refine === "Turbo"} />} />
        <PVRow title="Compacto — menos disco" sub="Downloaded · 826,7 MB" control={<PVGhostBtn danger>Eliminar</PVGhostBtn>} />
      </PVGroup>

      <PVSecTitle>Vocabulario · 13 términos</PVSecTitle>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
        {PV_VOCAB.map((v) => (
          <span key={v} style={{ display: "inline-flex", alignItems: "center", gap: 6, font: "500 11px/1 var(--font-app)", color: "rgba(255,255,255,0.85)", background: "rgba(255,255,255,0.07)", borderRadius: 999, padding: "6px 10px" }}>{v}<SFIcon name="xmark" size={8} color="rgba(255,255,255,0.4)" /></span>
        ))}
      </div>
      <span style={{ display: "flex", alignItems: "center", gap: 6, font: "400 11px/1.4 var(--font-app)", color: "#9d8cff" }}><SFIcon name="sparkles" size={11} color="var(--chip-ai-spark)" />8 sugeridos desde tus reuniones — clic para revisar antes de agregar</span>
    </>
  );
}
function PVPaneVoice() {
  return (
    <>
      <span style={{ font: "700 22px/1.2 var(--font-app)" }}>Mi voz y Companion</span>
      <PVGroup>
        <PVRow first title="Voz enrolada" sub="Solo se guarda una huella cifrada en este equipo — nunca audio, nunca en la nube" control={<span style={{ display: "flex", alignItems: "center", gap: 10 }}><span style={{ font: "400 11px/1 var(--font-mono)", color: "rgba(255,255,255,0.55)" }}>7 Jul 2026 · 10:38</span><PVGhostBtn danger>Eliminar mi voz</PVGhostBtn></span>} />
        <PVRow title="Tu nombre en reuniones" sub="Companion resalta la tarjeta cuando te preguntan por tu nombre" control={<span style={{ font: "500 12px/1 var(--font-app)", color: "rgba(255,255,255,0.7)", background: "rgba(255,255,255,0.08)", borderRadius: 6, padding: "6px 12px" }}>Johnny</span>} />
      </PVGroup>
    </>
  );
}
function PVPaneAgenda() {
  return (
    <>
      <span style={{ font: "700 22px/1.2 var(--font-app)" }}>Agenda y automatización</span>
      <PVGroup>
        <PVRow first title="Avísame antes de las reuniones" sub="un banner flotante aparece antes de tu próxima reunión del calendario — un clic inicia una grabación vinculada" control={<PVSeg options={["5 min", "1 min", "Off"]} value="5 min" />} />
        <PVRow title="Corre un Atajo cuando termina una reunión" sub="recibe la reunión en Markdown — conéctalo a Notes, Mail, Slack o lo que quieras" control={<span style={{ font: "500 12px/1 var(--font-app)", color: "rgba(255,255,255,0.7)", background: "rgba(255,255,255,0.08)", borderRadius: 6, padding: "6px 12px" }}>Ninguno</span>} />
      </PVGroup>
    </>
  );
}
function PVPaneIntegrations() {
  return (
    <>
      <span style={{ font: "700 22px/1.2 var(--font-app)" }}>Integraciones</span>
      <PVSecTitle>Modelo externo (BYOK)</PVSecTitle>
      <PVGroup>
        <PVRow first title="Endpoint compatible con OpenAI" control={<span style={{ font: "400 11px/1 var(--font-mono)", color: "rgba(255,255,255,0.6)" }}>https://api.openai.com/v1</span>} />
        <PVRow title="Modelo" control={<span style={{ font: "400 11px/1 var(--font-mono)", color: "rgba(255,255,255,0.6)" }}>gpt-4o-mini</span>} />
        <PVRow title="Clave API" control={<PVGhostBtn>Guardar en Keychain</PVGhostBtn>} />
        <PVRow title="Responder preguntas de conocimiento con este proveedor" sub="si el proveedor falla, la respuesta cae al modelo local" control={<PVToggle on={false} />} />
      </PVGroup>
      <PVSecTitle>GitHub</PVSecTitle>
      <PVGroup>
        <PVRow first title="Token personal (scope: gist)" sub="solo para publicar gists — se guarda en Keychain, nunca en la base de datos ni en la nube" control={<PVGhostBtn>Guardar en Keychain</PVGhostBtn>} />
      </PVGroup>
    </>
  );
}
function PVPaneData() {
  return (
    <>
      <span style={{ font: "700 22px/1.2 var(--font-app)" }}>Tus datos</span>
      <PVGroup>
        <PVRow first title="Exportar todas las reuniones (Markdown)" sub="un archivo Markdown por reunión — resumen, pendientes y transcript, en carpetas que eliges" control={<PVGhostBtn>Exportar…</PVGhostBtn>} />
        <PVRow title="Guardar grabaciones en" sub="/Users/johnny4young/Library/Application Support/Portavoz" control={<PVGhostBtn>Cambiar…</PVGhostBtn>} />
        <PVRow title="Plantilla de títulos" sub="vista previa: 2026-07-11 16.04 Reunión — chips {date} {time} {seq} {weekday}" control={<span style={{ font: "500 11px/1 var(--font-mono)", color: "rgba(255,255,255,0.6)", background: "rgba(255,255,255,0.08)", borderRadius: 6, padding: "6px 10px" }}>{"{date} {time} Reunión"}</span>} />
      </PVGroup>
      <PVSecTitle>Panel de tus datos — el ledger de privacidad</PVSecTitle>
      <div style={{ display: "flex", gap: 10 }}>
        {[["2.4 GB", "audio en tu disco"], ["128", "reuniones en SQLite tuyo"], ["0 B", "enviados a la red · 7 días", "#30d158"], ["1", "voz enrolada · cifrada aquí"]].map(([v, l, c]) => (
          <div key={l} style={{ flex: 1, padding: "13px 14px", borderRadius: 12, background: "rgba(255,255,255,0.05)", display: "flex", flexDirection: "column", gap: 2 }}>
            <span style={{ font: "700 17px/1.2 var(--font-app)", fontVariantNumeric: "tabular-nums", color: c || "#fff" }}>{v}</span>
            <span style={{ font: "400 10px/1.4 var(--font-app)", color: "rgba(255,255,255,0.5)" }}>{l}</span>
          </div>
        ))}
      </div>
      <span style={{ font: "400 11px/1.5 var(--font-app)", color: "rgba(255,255,255,0.4)" }}>«Tu historial jamás es rehén» hecho interfaz: ver qué existe, dónde vive, y exportarlo o borrarlo.</span>
    </>
  );
}

const PV_PANES = { general: PVPaneGeneral, audio: PVPaneAudio, intel: PVPaneIntel, voice: PVPaneVoice, agenda: PVPaneAgenda, integrations: PVPaneIntegrations, data: PVPaneData };

function PVSettings() {
  const [active, setActive] = React.useState("intel");
  const [hover, setHover] = React.useState(null);
  const Pane = PV_PANES[active];
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
          {PV_SET_NAV.map((n) => {
            const on = n.id === active;
            return (
              <button key={n.id} type="button" onClick={() => setActive(n.id)}
                onMouseEnter={() => setHover(n.id)} onMouseLeave={() => setHover(null)} style={{
                display: "flex", flexDirection: "column", gap: 2, padding: "7px 10px", borderRadius: 7,
                border: "none", cursor: "pointer", textAlign: "left", transition: "background 0.12s ease",
                background: on ? "linear-gradient(135deg, rgba(109,92,230,0.9), rgba(82,38,191,0.9))" : (hover === n.id ? "rgba(255,255,255,0.06)" : "transparent"),
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
        <Pane />
      </div>
    </div>
  );
}

window.PVSettings = PVSettings;
