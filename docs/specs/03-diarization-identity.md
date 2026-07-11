# Spec 03 — Diarización e identidad (DiarizationKit + naming)

Estado: implementado; DER verificado contra AMI real; reunión real procesada. Decisiones: D5 (Me estructural), D17 (threshold), D21 (voiceprint + nombres verificados).

## PyannoteDiarizer — `Sources/DiarizationKit/PyannoteDiarizer.swift`

- pyannote community-1 (segmentación) + WeSpeaker v2 (embeddings) vía FluidAudio; 10 artefactos sha256-pineados (~14 MB). `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)` carga por paths explícitos y **jamás descarga** (a diferencia de `AsrModels.load`).
- Streaming por ventanas de 10 s con `atTime` (el `SpeakerManager` interno mantiene S1/S2… estables entre ventanas) + `diarizeFile` batch.
- **`clusteringThreshold = 0.45` (D17) — NO SUBIR**: el wiring interno de FluidAudio multiplica ×1.2 (efectivo 0.54 de distancia coseno). Calibración medida: a 0.50 el sample AMI ya fusiona sus 2 speakers reales (DER 7.6% → 49.8%); pero en reunión remota real 0.45 fragmenta (11 clusters donde había ~4; distancias 0.55–0.64). La fragmentación se ataca post-clustering, no con el threshold.
- **`sanitizeTurns`**: labels que solo aparecen en la última ventana (zero-padded por el modelo) con quality < 0.35 se descartan — la ventana final rutinariamente pare un speaker fantasma (q ≈ 0.2). "Me" nunca se toca.
- **`mergeMicroClusters`** (solo batch/`diarizeFile`): labels con < 15 s de habla total ceden cada turno al label mayor temporalmente más cercano. Verificado: reunión real 11 → 4 speakers; AMI intacto (7.6%). Reglas biométricas: "Me" nunca absorbe ni es absorbido (un Me fantasma contaminaría owners de action items); sin majors disponibles los turnos quedan intactos (reunión corta ≠ fragmentación). 6 tests.
- Una instancia = una sesión (el SpeakerManager acumula la base de voces): reuniones distintas NO comparten diarizer.
- **No calibrar con TTS**: las voces de `say` comparten vocoder y son casi indistinguibles para WeSpeaker. Fixture de calibración: `sample.wav` + `sample.rttm` de pyannote-audio (AMI real, 2 speakers, ground truth público).

## Atribución — `SpeakerAttributor` (funciones puras)

- Canal mic → "Me" (verdad de hardware, D5). Canal system → turno con mayor overlap temporal.
- Segmentos multi-turno se parten en los límites de turnos con reparto proporcional de palabras. Sin turno → sin atribuir (honesto, editable en UI).
- Turnos etiquetados "Me" (voiceprint en canal system) se fusionan con la identidad del usuario.

## Diarización EN VIVO — `LiveSpeakerLabeler` (jul 2026)

Pedido de campo: dos voces remotas hablando seguido se fundían en una sola fila "Ellos" en vivo — no se veía que eran dos personas. Pipeline:

- `RecordingController` alimenta el canal system a una **instancia DEDICADA** de `PyannoteDiarizer` (SpeakerManager fresco por sesión — el pase batch al stop queda sin contaminar) vía `diarize(AsyncStream)`, ventanas de 10 s; la inferencia corre en el actor del diarizer (~14 MB, ms por ventana — nunca compite con el lane vivo de Parakeet).
- Con cada turno, `LiveSpeakerLabeler.relabel` (puro, idempotente, 7 tests) re-etiqueta las filas CERRADAS del system: una fila que cruza dos voces se **parte** en los límites de turnos (reusa `SpeakerAttributor`, reparto proporcional de palabras) y cada pieza muestra su pill **S1/S2** (o "Me"→"Yo" vía voiceprint). La última fila (aún creciendo, invariante del coalescer) jamás se toca; las filas sin ventana que las cubra siguen "Ellos". Las filas partidas obtienen ids nuevos → la traducción en vivo las recoge sola (traduce filas cerradas sin traducción).
- Las etiquetas vivas son **pistas efímeras**: al stop, el pase batch (`diarizeFile` + merge de micro-clusters + atribución) sigue siendo la verdad y re-atribuye todo desde el archivo; los S-números vivos no tienen por qué coincidir con los finales.
- Best-effort: si los modelos no cargan, el feed se cierra (no se acumula una reunión entera en memoria) y las captions quedan "Ellos" como antes.
- **Verificado con reunión real** (jul 2026): el path streaming encontró ≥2 voces en los primeros 4 min del canal system y los procesó en 2.4 s (~100× tiempo real) — test gated `testLiveStreamingPathFindsMultipleVoices`.

## Voiceprint — `VoiceprintStore` (D8/D21)

- Embedding WeSpeaker 256-dim de ~12 s de voz sola (el audio fuente NO se conserva). Cifrado AES-GCM; la llave SOLO en Keychain (service `app.portavoz.voiceprint-key`, inyectable para tests). `delete()` destruye archivo + llave en una acción. Jamás se sincroniza (se re-enrola por dispositivo).
- Enrolamiento: app (Ajustes → "Enrolar mi voz", 12 s) o CLI `voice enroll --file <wav>`. El diarizer lo carga con `initializeKnownSpeakers(isPermanent: true)` → label reservado "Me" cross-canal (reuniones híbridas: tu voz llegando por la sala/system también es tuya).

## Voces recordadas de participantes (jul 2026) — cross-meeting naming

Pedido de campo: recordar la voz de un participante entre reuniones para autosugerir su nombre. Reglas MÁS estrictas que el voiceprint propio (guardar biometría de terceros es más sensible, D8):

- **`VoiceGallery`** (`voice-gallery.enc`, mismo patrón que VoiceprintStore: AES-GCM, llave solo en Keychain service `app.portavoz.voice-gallery-key`, jamás sync). Una voz entra SOLO por gesto explícito: el chip "Remember X's voice?" que aparece tras confirmar un nombre (rename manual o chip aplicado). Re-recordar a alguien REEMPLAZA su embedding (uno por persona, case-insensitive). Individual removible (context menu en Ajustes → "Remembered voices") y "Forget all voices" destruye archivo + llave en una acción.
- **`PyannoteDiarizer.extractVoiceprints(fromFile:rangesBySpeaker:minimumSeconds:maximumSeconds:)`**: un embedding por speaker desde sus spans del canal system — resamplea el archivo UNA vez, corta por rangos (los más largos primero hasta 20 s; < 5 s se descarta: un embedding corto matchearía ruido). Los embeddings son transitorios: NADA se persiste aquí.
- **`VoiceMatcher`** (puro, 5 tests): distancia coseno propia (fuera de FluidAudio — el clustering interno no sirve cross-meeting), umbral `maxCosineDistance = 0.54` (la misma vara efectiva del clustering D17; pendiente calibración de campo). Cada speaker recibe a lo sumo su voz más cercana y cada voz de la galería se sugiere a lo sumo a un speaker (dos speakers no pueden ser ambos "Marta"). Embeddings degenerados (norma 0, dims distintas) jamás matchean.
- **UI (MeetingDetailView)**: al abrir un detalle con speakers sin nombre + galería no vacía, un diarizer EFÍMERO (~14 MB; los engines pesados NO se cargan) extrae y matchea una vez por visita → chips "S1 → ¿Marta?" con icono waveform (la evidencia es la voz, no el transcript — por eso NO pasa por `NameSuggestionFilter`). Mismo contrato D21: chip, click, jamás se aplica solo.

## Nombres automáticos (D21) — IntelligenceKit

- `SpeakerNamer.suggestNames`: propone label→nombre SOLO con evidencia. `NamingExcerpt` arma el contexto: primeras 3 intervenciones sustanciales (≥25 chars) por speaker + líneas que mencionan candidatos del calendario, cronológico, cap 2000 chars (un prefix ciego desbordaba la ventana de 4096 y solo veía el inicio). Retry con extracto a la mitad si aún desborda.
- **Never-trust-verify** (`NameSuggestionFilter`, puro y testeado): el nombre propuesto debe aparecer LITERALMENTE en el transcript completo O entre los asistentes del calendario (el modelo fabrica nombres con evidencia fabricada — observado: "John" de la nada).
- `CalendarAttendeeSource` (IntegrationsKit): asistentes de eventos EventKit alrededor de la reunión como candidatos (pide TCC de calendario).
- UI: chips "S1 → ¿Ana?" con evidencia en tooltip; un click aplica; nada se aplica solo.

## Evaluación — `DiarizationEvaluation` + `portavoz-cli der`

- `parseRTTM` + score con `DiarizationDER` de FluidAudio. **Unidades**: miss/falseAlarm/confusion llegan en SEGUNDOS y `der` en ratio → normalizar por el habla total de referencia.
- Medido: **AMI 7.6%** (miss 3.7 / FA 1.3 / conf 2.6, collar 0.25 s) — criterio M3 < 15% ✓.

## Límites conocidos

1. DER formal de reunión real pendiente (borrador RTTM esperando corrección del usuario en `~/Desktop/portavoz-verificacion/`).
2. Sortformer (mejor para diálogo rápido, según humla) no evaluado; SpeakerKit de Argmax (mismo paquete que WhisperKit) es alternativa a benchmarkear.
3. La atribución con filas coalescidas largas depende más del reparto proporcional (aceptable, no medido por separado).
