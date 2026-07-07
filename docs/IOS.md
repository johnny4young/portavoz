# iOS/iPadOS — aterrizaje técnico (fase 3, M14)

Complementa D11 (estrategia) y el ROADMAP (M14a–d). Este documento existe para que la fase 3 empiece con cero fantasías: **qué es técnicamente realizable en iOS, con qué APIs, y qué presupuesto de recursos tiene cada pieza**.

## La verdad de la captura (por qué iOS ≠ Mac)

| Capacidad | macOS | iOS | API/razón |
|---|---|---|---|
| Audio del sistema (otras apps) | ✅ process taps | ❌ imposible | Sandbox; no existe equivalente a `CATapDescription` |
| Grabación de llamadas de terceros (Zoom/Meet/Teams) | ✅ vía tap | ❌ imposible | Ninguna API pública; la grabación de llamadas iOS 18.1+ es exclusiva de la app Teléfono |
| Mic en background | ✅ | ✅ con `UIBackgroundModes: audio` | Grabación continua legítima; el indicador naranja siempre visible |
| Broadcast de pantalla | n/a | ⚠️ ReplayKit `RPBroadcastSampleHandler` | Solo audio DE APPS QUE LO PERMITEN, límite 50 MB de RAM en la extensión, la llamada de Zoom NO entrega su audio — sirve como importador experimental, jamás como promesa |

Conclusión D11 (se mantiene): el iPhone es **grabadora presencial + companion**. Todo lo demás es honestidad de producto.

## Qué compila hoy y qué hay que tocar (M14a)

- `Package.swift` ya declara `.iOS(.v17)`. Auditoría por Kit:
  - **PortavozCore, StorageKit, IntelligenceKit, IntegrationsKit, ContextFeedKit**: portables tal cual (GRDB, FM y NLContextualEmbedding existen en iOS; FM requiere iOS 26).
  - **AudioCaptureKit**: `ProcessTapSource` es macOS-only (ya está tras `#if os(macOS)`); `MicrophoneSource` necesita rama iOS: `AVAudioSession` (categoría `.playAndRecord`, modo `.measurement` o `.voiceChat` para AEC — en iOS el voice processing viene por el modo de sesión), interrupciones (llamada entrante → pausa + gap de silencio, la misma maquinaria del device-change de macOS aplica), ruta Bluetooth (`allowBluetoothHFP` vs `bluetoothHighQualityRecording` iOS 26 para AirPods en calidad estudio).
  - **TranscriptionKit**: Parakeet TDT v3 int8 (~483 MB) corre en ANE de iPhone 12+ (FluidAudio soporta iOS). **Whisper large-v3-turbo (1.6 GB) NO cabe razonablemente en iPhone** → el refine móvil usa `SpeechAnalyzer` (iOS 26, gratis) o whisper-small; o se difiere a la Mac vía sync ("refine donde haya vatios").
  - **DiarizationKit**: pyannote+WeSpeaker (~14 MB) corre en iOS sin drama. El voiceprint se sincroniza JAMÁS (D8): se re-enrola por dispositivo.
- **La app iOS requiere proyecto Xcode** (fin de la era D20-solo-SPM): target app iOS + extensiones (share, broadcast experimental, widgets/Live Activity). El package SPM sigue siendo la única fuente de los Kits.

## Presupuestos por dispositivo (a validar en M14a con `bench` móvil)

| Dispositivo | STT vivo | Refine local | LLM resumen |
|---|---|---|---|
| iPhone 12–14 (4–6 GB) | Parakeet int8 ✅ | whisper-small o diferir a Mac | FM si iOS 26+AI; si no, diferir/BYOK |
| iPhone 15 Pro+ (8 GB) | Parakeet int8 ✅ | SpeechAnalyzer ✅ | FM on-device ✅ |
| iPad M-series | = Mac (sin taps) | Whisper turbo viable | FM ✅ |

Reglas: STT vivo se degrada ANTES de tirar la grabación (guardar WAV siempre es barato); `ProcessInfo.thermalState` ≥ `.serious` → apagar captions vivas, seguir grabando; batería < 20% → ofrecer "solo grabar".

## Sync (M14c): CKSyncEngine, no servidor propio

- **Qué sincroniza**: meetings/speakers/segments/summaries (el schema D4 ya es sync-ready: UUIDs, tombstones, `updatedAt`). Audio NO por defecto (grande); opt-in por reunión con asset CKAsset.
- **Cifrado**: `encryptedValues` en todos los campos de contenido; con Advanced Data Protection del usuario, E2E real.
- **Conflictos**: last-writer-wins por campo con `updatedAt` (los summaries son snapshots inmutables — jamás conflicto); tombstones ganan siempre.
- **Voiceprint y llaves: nunca** (D8/D21).
- Companion: control remoto de la grabación de la Mac vía CloudKit push (record de "comando" efímero) — cero infraestructura propia.

## Live Activity + Dynamic Island (M14c)

- ActivityKit: timer + última caption coalescida (el coalescer ya da la línea estable) + botón detener. Update budget: ActivityKit limita frecuencia → actualizar por FRASE cerrada, no por delta (otra vez el coalescer paga).
- Long-press/botón = "marcar momento" (timestamp → clip candidato en M9).

## Lo que NO haremos en iOS (anti-promesas)

- Grabar llamadas de otras apps (imposible).
- Whisper large en iPhone (presupuesto de RAM/térmico irreal).
- Sync propietario con backend nuestro antes de L2 (D12).
- Voiceprint sincronizado (biometría se queda donde nació).
