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

## Voiceprint — `VoiceprintStore` (D8/D21)

- Embedding WeSpeaker 256-dim de ~12 s de voz sola (el audio fuente NO se conserva). Cifrado AES-GCM; la llave SOLO en Keychain (service `app.portavoz.voiceprint-key`, inyectable para tests). `delete()` destruye archivo + llave en una acción. Jamás se sincroniza (se re-enrola por dispositivo).
- Enrolamiento: app (Ajustes → "Enrolar mi voz", 12 s) o CLI `voice enroll --file <wav>`. El diarizer lo carga con `initializeKnownSpeakers(isPermanent: true)` → label reservado "Me" cross-canal (reuniones híbridas: tu voz llegando por la sala/system también es tuya).

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
