// Recording view + floating HUD — recreation of RecordingView.swift / RecordingHUD.swift.
const { Button, Card, MicMeter, SFIcon, FloatingPanel } = window.PortavozDesignSystem_fd5562;

function PVTimer({ running }) {
  const [sec, setSec] = React.useState(767);
  React.useEffect(() => {
    if (!running) return undefined;
    const id = setInterval(() => setSec((s) => s + 1), 1000);
    return () => clearInterval(id);
  }, [running]);
  const mm = String(Math.floor(sec / 60)).padStart(2, "0");
  const ss = String(sec % 60).padStart(2, "0");
  return <span style={{ font: "500 24px/1 var(--font-app)", fontVariantNumeric: "tabular-nums", color: "var(--text-primary)" }}>{mm}:{ss}</span>;
}

function PVRecording({ onStop, onHud }) {
  const [level, setLevel] = React.useState(0.6);
  React.useEffect(() => {
    const id = setInterval(() => setLevel(0.35 + Math.random() * 0.45), 180);
    return () => clearInterval(id);
  }, []);
  return (
    <div style={{ flex: 1, overflowY: "auto" }}>
      <div style={{ display: "flex", flexDirection: "column", gap: 16, padding: 24, maxWidth: 760 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <span className="pv-pulse" style={{ width: 10, height: 10, borderRadius: 999, background: "var(--destructive)", animation: "pv-pulse var(--pulse-duration) var(--ease-standard) infinite" }}></span>
          <PVTimer running />
          <MicMeter fraction={level} width={90} />
          <span style={{ flex: 1 }}></span>
          <Button size="small" icon={<SFIcon name="arrow.up.left.and.arrow.down.right" size={12} />} onClick={onHud}>HUD</Button>
          <Button variant="destructive" icon={<SFIcon name="stop.circle.fill" size={13} />} onClick={onStop}>Stop</Button>
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 12, padding: "18px 0" }}>
          <div style={{ display: "flex", alignItems: "baseline", gap: 9, opacity: 0.3, filter: "blur(1.5px)" }}>
            <span style={{ font: "600 10px/1 var(--font-app)", background: "var(--pill-neutral)", borderRadius: 999, padding: "3px 7px", color: "var(--text-primary)" }}>Ellos</span>
            <span style={{ font: "400 14px/1.5 var(--font-app)", color: "var(--text-secondary)" }}>…el pipeline quedó verde anoche.</span>
          </div>
          <div style={{ display: "flex", alignItems: "baseline", gap: 10, padding: "14px 18px", borderRadius: 14, background: "color-mix(in srgb, var(--voice-me) 12%, transparent)", boxShadow: "inset 0 0 0 1px color-mix(in srgb, var(--voice-me) 35%, transparent)" }}>
            <span style={{ font: "600 10px/1 var(--font-app)", color: "var(--voice-me-contrast)", background: "var(--voice-me)", borderRadius: 999, padding: "3px 7px" }}>Yo</span>
            <span style={{ font: "500 18px/1.45 var(--font-app)", color: "var(--text-primary)" }}>¿Cerramos entonces el <span style={{ color: "var(--accent)" }}>bug del device-ID duplicado</span> en QVTL?</span>
          </div>
          <div style={{ display: "flex", alignItems: "baseline", gap: 9, opacity: 0.45, filter: "blur(0.7px)" }}>
            <span style={{ font: "600 10px/1 var(--font-app)", color: "var(--voice-2)", background: "color-mix(in srgb, var(--voice-2) 22%, transparent)", borderRadius: 999, padding: "3px 7px" }}>Ilarion</span>
            <span style={{ font: "400 15px/1.5 var(--font-app)", color: "var(--text-secondary)" }}>Sí, era el cache del provisioning…</span>
          </div>
          <span style={{ font: "var(--type-caption)", color: "var(--text-tertiary)" }}>lyrics tipo Spotify — suben solas, blur en extremos, karaoke palabra a palabra</span>
        </div>
        <Card variant="companion" kicker="They mentioned you" icon={<SFIcon name="sparkles" size={11} />}>
          Marta asked if you can lead the client demo on Monday.
        </Card>
        <Card variant="content" title="Notes">
          <span style={{ font: "var(--type-body)", color: "var(--text-secondary)" }}>
            Drop links, decisions or snippets here — they co-author the summary (▸).
          </span>
        </Card>
      </div>
    </div>
  );
}

function PVRecordingHUD({ onExpand, onStop }) {
  const [level, setLevel] = React.useState(0.6);
  React.useEffect(() => {
    const id = setInterval(() => setLevel(0.35 + Math.random() * 0.45), 180);
    return () => clearInterval(id);
  }, []);
  return (
    <div style={{ position: "absolute", top: 16, right: 16, zIndex: 10 }}>
      <FloatingPanel variant="hud">
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
            <span className="pv-pulse" style={{ width: 8, height: 8, borderRadius: 999, background: "var(--destructive)", animation: "pv-pulse var(--pulse-duration) var(--ease-standard) infinite" }}></span>
            <span style={{ font: "500 12px/1 var(--font-app)", fontVariantNumeric: "tabular-nums", color: "var(--text-primary)" }}>12:47</span>
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 3, flex: 1, minWidth: 0 }}>
            <span style={{ font: "var(--type-caption)", color: "var(--text-secondary)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
              …el fix está en main y lo verificamos contra los 40 dispositivos.
            </span>
            <MicMeter fraction={level} width={90} />
          </div>
          <button type="button" onClick={onExpand} title="Back to the full window"
            style={{ border: "none", background: "none", cursor: "pointer", display: "flex", padding: 2 }}>
            <SFIcon name="arrow.up.left.and.arrow.down.right" size={13} color="var(--text-secondary)" />
          </button>
          <button type="button" onClick={onStop} title="Stop recording"
            style={{ border: "none", background: "none", cursor: "pointer", display: "flex", padding: 2 }}>
            <SFIcon name="stop.circle.fill" size={18} color="var(--destructive)" />
          </button>
        </div>
      </FloatingPanel>
    </div>
  );
}

Object.assign(window, { PVRecording, PVRecordingHUD });
