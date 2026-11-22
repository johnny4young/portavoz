// Library sidebar — sunk paper with ink chrome, and the
// signature detail: every meeting row carries its VOICE MIX bar (who spoke,
// in voice colors; amber = you). The library becomes a shelf of
// conversations you can read at a glance — no other meeting app has this.
const { SFIcon } = window.PortavozDesignSystem_fd5562;
const pvData = window.PV_DATA;

const PV_VOICE = (v) => v === "me" ? "var(--voice-me)" : v ? `var(--voice-${v})` : "rgba(255,255,255,0.22)";

function PVMixBar({ mix, height = 4 }) {
  return (
    <div style={{ display: "flex", gap: 2, height, borderRadius: 99, overflow: "hidden", marginTop: 4 }}>
      {mix.map((seg, i) => (
        <span key={i} style={{ width: `${seg.w}%`, borderRadius: 99, background: PV_VOICE(seg.v), opacity: seg.v === "me" ? 1 : 0.8 }}></span>
      ))}
    </div>
  );
}

function PVSectionLabel({ children }) {
  return <span style={{ font: "600 9.5px/1.3 var(--font-app)", letterSpacing: "0.09em", textTransform: "uppercase", color: "rgba(255,255,255,0.32)", padding: "10px 10px 3px" }}>{children}</span>;
}

function PVActionChip({ icon, label, onClick, active }) {
  return (
    <button type="button" onClick={onClick} style={{
      display: "flex", flexDirection: "column", alignItems: "center", gap: 5,
      flex: 1, padding: "9px 4px", borderRadius: 11, border: "none", cursor: "pointer",
      font: "600 9.5px/1 var(--font-app)",
      background: active ? "var(--selection)" : "rgba(255,255,255,0.06)",
      color: active ? "var(--ink)" : "rgba(255,255,255,0.72)",
    }}>
      <SFIcon name={icon} size={14} color={active ? "var(--ink)" : "rgba(255,255,255,0.72)"} />
      {label}
    </button>
  );
}

function PVSidebar({ route, onRoute, todos, onToggleTodo }) {
  const [query, setQuery] = React.useState("");
  const openTodos = todos.filter((t) => !t.done).length;
  return (
    <div style={{
      width: 256, flexShrink: 0, display: "flex", flexDirection: "column",
      background: "var(--paper-2)",
      borderRight: "0.5px solid rgba(255,255,255,0.09)",
    }}>
      <div style={{ display: "flex", gap: 8, padding: "12px 14px 0" }}>
        <span style={{ width: 11, height: 11, borderRadius: 999, background: "#ff5f57" }}></span>
        <span style={{ width: 11, height: 11, borderRadius: 999, background: "#febc2e" }}></span>
        <span style={{ width: 11, height: 11, borderRadius: 999, background: "#28c840" }}></span>
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 9, padding: "12px 14px 6px" }}>
        <button type="button" onClick={() => onRoute("recording")} style={{
          position: "relative", overflow: "hidden",
          display: "flex", alignItems: "center", justifyContent: "center", gap: 8,
          font: "500 13px/1 var(--font-app)", padding: "10px 14px", borderRadius: 10,
          border: "none", cursor: "pointer", color: "var(--on-accent)",
          background: "var(--accent)",
        }}>
          <span style={{ display: "flex", alignItems: "flex-end", gap: 1.5, height: 13 }}>
            <i style={{ width: 2.5, height: "45%", borderRadius: 99, background: "var(--on-accent)" }}></i>
            <i style={{ width: 2.5, height: "100%", borderRadius: 99, background: "var(--voice-me)" }}></i>
            <i style={{ width: 2.5, height: "60%", borderRadius: 99, background: "var(--on-accent)" }}></i>
          </span>
          Nueva grabación
        </button>
        <div style={{ display: "flex", gap: 6 }}>
          <PVActionChip icon="square.and.arrow.down" label="Importar" onClick={() => {}} />
          <PVActionChip icon="bubble.left.and.text.bubble.right" label="Preguntar" active={route === "ask"} onClick={() => onRoute("ask")} />
          <PVActionChip icon="chart.bar.xaxis" label="Insights" active={route === "insights"} onClick={() => onRoute("insights")} />
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 7, background: "rgba(255,255,255,0.07)", borderRadius: 8, padding: "6px 9px" }}>
          <SFIcon name="magnifyingglass" size={12} color="rgba(255,255,255,0.4)" />
          <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Buscar en todo…"
            style={{ flex: 1, font: "400 12px/1 var(--font-app)", color: "rgba(255,255,255,0.87)", background: "none", border: "none", outline: "none", minWidth: 0 }} />
          <span style={{ font: "500 9px/1 var(--font-mono)", color: "rgba(255,255,255,0.35)", background: "rgba(255,255,255,0.08)", borderRadius: 4, padding: "3px 5px" }}>⌘K</span>
        </div>
      </div>

      <div style={{ flex: 1, overflowY: "auto", display: "flex", flexDirection: "column", gap: 1, padding: "0 10px 12px" }}>
        <PVSectionLabel>Hoy</PVSectionLabel>
        <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "7px 10px", borderRadius: 9, background: "rgba(253,191,71,0.08)", boxShadow: "inset 0 0 0 1px rgba(253,191,71,0.22)", cursor: "pointer" }}>
          <SFIcon name="calendar.badge.clock" size={13} color="var(--voice-me)" />
          <span style={{ font: "400 10px/1 var(--font-mono), var(--font-app)", color: "rgba(255,255,255,0.5)" }}>14:30</span>
          <span style={{ font: "400 12.5px/1.3 var(--font-app)", color: "rgba(255,255,255,0.87)", flex: 1 }}>Retro sprint 15</span>
          <span style={{ font: "600 9px/1 var(--font-app)", color: "var(--voice-me)" }}>✦ brief</span>
        </div>

        <PVSectionLabel>Pendientes · {openTodos}</PVSectionLabel>
        {todos.map((t) => (
          <div key={t.id} style={{ display: "flex", gap: 7, padding: "5px 10px", alignItems: "flex-start" }}>
            <input type="checkbox" checked={!!t.done} onChange={() => onToggleTodo(t.id)}
              style={{ accentColor: "var(--ink)", marginTop: 2, cursor: "pointer" }} />
            <span onClick={() => onRoute("m1")} style={{
              font: "400 12px/1.4 var(--font-app)", cursor: "pointer",
              color: "rgba(255,255,255,0.82)",
              textDecoration: t.done ? "line-through" : "none", opacity: t.done ? 0.45 : 1,
            }}>{t.text}</span>
          </div>
        ))}

        <PVSectionLabel>Reuniones</PVSectionLabel>
        {pvData.meetings.map((m) => {
          const selected = route === m.id;
          return (
            <div key={m.id} onClick={() => onRoute(m.id)} style={{
              display: "flex", flexDirection: "column", padding: "7px 10px 8px", borderRadius: 9, cursor: "pointer",
              background: selected ? "var(--card)" : "transparent",
              boxShadow: selected ? "0 0 0 0.5px var(--line-2), 0 1px 3px rgba(0,0,0,0.25)" : "none",
            }}>
              <span style={{ font: selected ? "500 12.5px/1.35 var(--font-app)" : "400 12.5px/1.35 var(--font-app)", color: selected ? "var(--ink)" : "rgba(255,255,255,0.85)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{m.title}</span>
              <span style={{ font: "400 9.5px/1.4 var(--font-app)", fontVariantNumeric: "tabular-nums", color: selected ? "rgba(255,255,255,0.72)" : "rgba(255,255,255,0.38)" }}>{m.date} · {m.min} min</span>
              <PVMixBar mix={m.mix} />
            </div>
          );
        })}

        <PVSectionLabel>Eliminadas</PVSectionLabel>
        {pvData.trashed.map((d) => (
          <div key={d.id} style={{ display: "flex", alignItems: "center", gap: 8, padding: "5px 10px", borderRadius: 9 }}>
            <div style={{ display: "flex", flexDirection: "column", flex: 1, minWidth: 0 }}>
              <span style={{ font: "400 12px/1.35 var(--font-app)", color: "rgba(255,255,255,0.45)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{d.title}</span>
              <span style={{ font: "400 9.5px/1.4 var(--font-app)", color: "rgba(255,255,255,0.32)" }}>Borrado, no perdido — {d.caption}</span>
            </div>
            <SFIcon name="arrow.uturn.backward" size={12} color="var(--ink-3)" />
          </div>
        ))}
      </div>

      <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "11px 14px", borderTop: "0.5px solid rgba(255,255,255,0.08)" }}>
        <span className="pv-pulse" style={{ width: 7, height: 7, borderRadius: 999, background: "#30d158", animation: "pv-pulse 3.6s ease-in-out infinite" }}></span>
        <span style={{ font: "400 10px/1.4 var(--font-app)", color: "rgba(255,255,255,0.45)" }}>Local-first · transferencias con opt-in</span>
        <span style={{ flex: 1 }}></span>
        <span style={{ font: "500 8.5px/1 var(--font-mono)", color: "rgba(255,255,255,0.3)" }}>tu barra ámbar =<br />cuánto hablaste</span>
      </div>
    </div>
  );
}

window.PVSidebar = PVSidebar;
