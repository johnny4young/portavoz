# Spec 06 — App macOS (portavoz-app + scripts de empaquetado)

Estado: implementado, firmado con Developer ID, **notarizado por Apple (0.1.0, Accepted + stapled)** y usado en reuniones reales. Decisiones: D20 (SPM + script, sin proyecto Xcode), D23 (empaquetado), D10 (distribución).

## Estructura

`portavoz-app` es un `executableTarget` SPM (SwiftUI + Observation, @MainActor). `scripts/make-app.sh [--release]` arma `dist/Portavoz.app`: Info.plist (usage descriptions: mic, audio del sistema, calendario, carpetas Desktop/Documents/Downloads/volúmenes removibles), embebe `Sparkle.framework` + rpath, firma XPCs internos, hardened runtime (`--options runtime`) + `--timestamp` con identidad real + entitlement `com.apple.security.device.audio-input` (sin él, el hardened runtime bloquea el mic). **Sin sandbox.**

- Firma: por SHA-1 del cert (`PORTAVOZ_SIGN_IDENTITY`) — hay DOS Developer ID con el mismo nombre en la máquina y el nombre es ambiguo.
- `make-dmg.sh`: DMG UDZO + symlink /Applications; con `PORTAVOZ_NOTARY_PROFILE` notariza (notarytool + staple).
- `make-release.sh <v>`: estampa versión, DMG, `generate_appcast --account portavoz` (llave EdDSA dedicada — la default del Keychain es de OTRO proyecto), cask con sha256 → `dist/release/`.
- Sparkle 2.9: menú "Buscar actualizaciones…" (`SPUStandardUpdaterController`); `SUFeedURL` apunta al release de GitHub; llave pública en `assets/sparkle-public-key`.

## Composición — `AppServices` (@MainActor @Observable)

DB (`MeetingStore`) + engines lazy compartidos: `transcriber` (Parakeet), `diarizer` (con voiceprint si existe; `invalidateDiarizer()` tras enrolar/borrar), `whisper` (lazy, primera vez descarga verificada 1.6 GB con progreso). `modelsState` para la UI de descargas; `libraryVersion` invalida listas/detalle (las vistas recargan con `.task(id:)`).

## Vistas y flujos

**LibraryView**: Nueva grabación (⌘N), búsqueda FTS con snippets, lista con context menu Renombrar/Eliminar.

**RecordingView + RecordingController** (el pipeline vivo completo):
1. `start`: warm-up del mic (AEC converge durante "Preparando…"), engines, `RecordingSession` con mic (+tap del sistema en 14.4+), feeds por canal → Parakeet vivo → **CaptionCoalescer** (una fila por intervención).
2. En vivo: captions en LazyVStack (ventana 150 filas) con **follow-live pausable** (scroll manual pausa; reanuda a los 10 s o con el botón "Seguir en vivo"); picker de traducción →es/→en (Translation framework, macOS 15+; solo traduce filas cerradas); **resumen rodante monotónico** cada ~40 s (nota FM solo de filas cerradas nuevas → pila → colapso > 6000 chars → render; nunca encoge — `LiveSummaryPolicy`).
3. `stop`: diariza el canal system → `SpeakerAttributor` → guarda meeting (título por **plantilla configurable** `TitleTemplate`: `{date} {time} {seq} {weekday}`, ISO-first) + cast → resumen final FM (con vocabulario como glosario) → detalle.

**MeetingDetailView**: header con título editable (lápiz), pills de speaker editables (captura de valores al tap — el alert-dismiss nileaba el estado y el rename se perdía), chips "Sugerir nombres ✦" con evidencia, resumen versionado con regenerar (es/en), transcript lazy, action items chequeables.
- **Refinar (D7 in-app)**: re-transcribe ambos canales con Whisper (+vocabulario), re-diariza (merge de micro-clusters), y presenta **DRAFT con sheet de comparación** (segmentos/hablantes/habla cubierta/muestra + warning rojo si cubre < 50% del habla actual) — **nada se aplica sin "Aplicar"** (un refine defectuoso reemplazó una reunión real; el draft-flow y los tombstones son la doble defensa). Al aplicar: `replaceCast` + regenerar resumen.
- Exportar: Markdown / PDF (CoreText puro, compila para iOS) / **Gist secreto** con confirmación off-device explícita.

**SettingsView (⌘,)**: Audio (toggle AEC) · Grabaciones (carpeta configurable con migración y progreso) · Títulos (plantilla con help popover de tokens, chips insertables, botón Restablecer y preview en vivo) · Vocabulario (editor de lista: Enter añade, − quita) · Mi voz (enrolar 12 s / borrar — destruye archivo+llave) · Modelo externo BYOK (endpoint/modelo en defaults, key en Keychain, toggle de opt-in del Companion deshabilitado hasta configurar todo; eliminar la key lo apaga — spec 04) · GitHub (token en Keychain).

## Verificado en el mundo real (jul 2026)

4 reuniones reales grabadas; permisos TCC estables entre updates (identidad de firma real); grabación de 30 min sobrevivió cambio de dispositivo a mitad (post-fix); AEC eliminó el eco de parlantes; incidente de refine recuperado sin pérdida.

## Límites conocidos

1. **Audio first-class (M11/D27) completo**: player sincronizado con **transcript estilo letras de Spotify** (`FocusedTranscriptView`: la línea hablada se queda CENTRADA en un viewport de altura fija, las demás se desvanecen/encogen/desenfocan hacia los bordes — efecto papel-cilindro con `.visualEffect`; sin barra de scroll; buscar en el timeline mueve el transcript DENTRO de su caja, nunca la página), click-para-saltar, **waveform-scrubber** (coloreado por canal: acento=tú, gris=ellos; atenuado tras el playhead; región del clip sombreada) y **clips** (marcar in/out en el playhead → `AudioClipExporter` exporta el rango mezclado a m4a/AAC vía `AVAssetExportSession`, medido muy por debajo de 2 s) — todo en `AudioPlaybackKit`. Sin audio, el transcript es lista normal. El **mismo carrusel corre en grabación en vivo** (`FocusedTranscriptView` parametrizado con `anchor`: en grabación la línea nueva se enfoca en el tercio inferior `y≈0.82` — la frontera — y las viejas suben y se desvanecen; `followSignal` re-centra cuando la línea viva CRECE, no solo al aparecer una nueva; reemplazó el follow-live pausable). También: **skip-silencio** (toggle; salta gaps ≥1.2 s detectados del waveform), **transcode AAC** ("Comprimir audio (AAC)" → `AudioTranscoder`, borra el original tras escritura verificada, reconstruye el player desde el m4a) e **import** (biblioteca: botón "Importar audio…" + drag-drop → `AppServices.importMeeting`: copia como canal system, Whisper + diarización + resumen, navega a la reunión nueva). **M11 completo.** `make test-ui` cubre player, highlight y clip export button; el preflight cierra Portavoz antes de XCUITest para evitar fallos de automation mode por instancias stale.
2. Sin HUD flotante/menu bar: grabar exige la ventana completa (los competidores tienen panel compacto).
3. UI solo en español — sin localización (GAPS).
