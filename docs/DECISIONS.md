# Registro de decisiones

Formato ADR ligero: cada entrada es una decisión tomada, su contexto y su porqué. Las decisiones aquí son vinculantes hasta que una entrada posterior las reemplace explícitamente.

## D1 — Reescritura 100% Swift, sin reutilizar el core Rust de Meetily

**Contexto:** Meetily (~44K LOC Rust + ~30K TS sobre Tauri) es la referencia conceptual. Su core es mayormente FFI hacia APIs de Apple (crate `cidre` → Core Audio) y modelos que la comunidad ya portó a CoreML.
**Decisión:** Swift 6 + SwiftUI nativo; nada de FFI Rust.
**Porqué:** WhisperKit/FluidAudio/GRDB cubren todo lo que el Rust aportaba, mejor y sin capa intermedia; un solo lenguaje maximiza mantenibilidad; el ANE (CoreML) consume ~10x menos energía que GPU. Costo aceptado: se pierde Windows/Linux — Portavoz es Apple-only por diseño.

## D2 — Nombre: Portavoz

**Decisión:** El proyecto se llama **Portavoz** ("el que lleva tu voz"). Dominio `portavoz.app` comprado; repo `johnny4young/portavoz`; considerar org `portavoz-app` (libre a 2026-07-06) antes del lanzamiento público.
**Porqué:** Nombra el presente (portavoz de lo dicho en la reunión) y el futuro del roadmap (la app que un día hablará por el usuario). Historia: Timbral fue líder tentativo (concepto: firma tímbrica de cada voz; timbral.app/.dev + GitHub estaban libres). Muertos por colisión: Acta (acta.ai), Minuta (minuta.app), Timbre (editor con transcripción), Tertulia (startup de libros), Dixo (≈Dixa), Batuta (cybersecurity $20.5M), Quorum, Relata, Rimay (≈RemyAI), Sonar (SonarQube), Coro (cybersecurity). Colisión conocida y aceptada de Portavoz: rapero chileno homónimo (no-software).

## D3 — Licencia MIT + higiene GPL

**Decisión:** Todo el código MIT. **Prohibido portar código de proyectos GPL** — en particular MacParakeet (GPL-3), que valida nuestro stack pero es mirar-sin-tocar. Humla (MIT) y FluidAudio/WhisperKit (MIT/Apache) sí permiten reutilización con atribución.
**Porqué:** máxima adopción, compatible con el modelo PRO y con IAP en App Store; precedente directo: Humla.

## D4 — Persistencia: GRDB (SQLite) + contrato de schema congelado desde v1

**Decisión:** GRDB + FTS5 + sqlite-vec (llega en M1/M5; M0 sin dependencias). NO SwiftData.
**Contrato inmutable:** (1) PKs UUID en todo, jamás autoincrement; (2) `updated_at` + `deleted_at` (tombstones) en tablas sincronizables; (3) summaries como **snapshots inmutables versionados**; (4) cero rutas absolutas en la DB; (5) API keys jamás en SQLite ni UserDefaults → Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`); (6) campo `visibility` reservado desde v1.
**Porqué:** validado en producción por MacParakeet y Humla; SwiftData no ofrece FTS ni índice vectorial; el contrato hace el schema "sharing-ready" sin migración dolorosa. Anti-patrón de referencia: Meetily guarda API keys en SQLite plano.

## D5 — Captura dual-canal: nunca mezclar antes de diarizar

**Decisión:** Micrófono y audio del sistema se capturan y persisten como **canales separados** (`microphone.wav` / `system.wav`). Todo lo que entra por el mic es del usuario por definición de hardware ("who-said-what estructural"); la diarización ML solo corre sobre el canal remoto/sala.
**Porqué:** identifica las intervenciones del usuario con precisión ~100% sin ML. Meetily mezcla los canales y destruye esa información. Validado por Humla (dual-stream con sidecars Swift).

## D6 — Audio del sistema: process taps por app (no BlackHole, no tap global por defecto)

**Decisión:** Core Audio process taps (macOS 14.4+) apuntando a PIDs específicos (Zoom/Meet/Teams). El tap global existe solo como opción explícita.
**Porqué:** sin drivers virtuales ni instalación extra; capturar solo la app de la reunión evita contaminar el transcript con música/notificaciones y es mejor historia de privacidad. Fija el target mínimo: **macOS 14.4** (iOS 17 para WhisperKit).

## D7 — Multi-modelo: routing por tarea, jamás un modelo global

**Decisión:** Protocolos `TranscriptionEngine`/`SummaryProvider` + registry curado (JSON con id, tarea, sha256 pineado, revisión upstream, RAM mínima, licencia) + router por `ModelTask`.
**Recomendaciones por defecto:** STT vivo = Parakeet v3 (FluidAudio/ANE) o SpeechAnalyzer (macOS 26+); re-pase final = Whisper large-v3-turbo (WhisperKit); diarización = pyannote community-1 (alternativa Sortformer); resumen local = Foundation Models, escalando a Qwen3 4B (MLX); títulos/embeddings = modelos chicos; traducción = Translation framework del OS. Overrides por idioma (patrón Humla) y por hardware.
**Regla de scheduler:** lo vivo nunca espera a lo batch (slots separados, patrón MacParakeet).
**Porqué:** cada tarea tiene un óptimo distinto; la verificación sha256 es obligatoria (un modelo es código que ejecutas). Feature pedida en issues de Meetily: modelos custom de HF — soportada por el registry.

## D8 — Privacidad: local por defecto, BYOK explícito, telemetría opt-in

**Decisión:** resumen/transcripción/diarización locales por defecto; enviar transcript a un LLM cloud requiere opt-in visible y etiquetado, jamás default silencioso. Telemetría **opt-in** (Meetily trae PostHog opt-out). Voiceprints = dato biométrico: solo on-device, cifrado, nunca en sync, borrable con una acción. Disclosure de grabación con presets por jurisdicción (consentimiento de dos partes).
**Porqué:** es el posicionamiento del producto entero; la crítica pública a Meetily ("mandar a Claude/Groq reintroduce la nube") lo confirma.

## D9 — Modelo de negocio: FREE ilimitado local + PRO de pago único

**Decisión:** FREE nunca limita minutos/reuniones/historial (la computación local del usuario es gratis). PRO = licencia de pago único (~US$69, lanzamiento $49; IAP no-consumable en iOS): sync CloudKit multi-dispositivo, integraciones dev (GitHub/Linear/Jira), chat RAG sobre historial, servidor MCP, clips exportables, Recipes avanzadas, enrollment de voz + nombres automáticos, meeting-health. Upgrades pagos solo en versiones mayores (modelo MacWhisper).
**Estrategia OSS:** todo el código abierto; PRO como "llave de cortesía" — quien compila desde el código lo tiene todo; quien descarga el binario firmado paga.
**Porqué:** Fathom probó que el free ilimitado es motor de crecimiento; Otter probó que el free tacaño mata; MacWhisper (€59) y superwhisper ($249 lifetime) probaron el pago único en esta categoría exacta en Mac.

## D10 — Distribución

**Decisión:** macOS: DMG notarizado + Sparkle 2 + Homebrew cask + venta directa (Paddle/Lemon Squeezy). iOS/visionOS: App Store con IAP. CLI público como canal de adquisición dev.
**Porqué:** patrón completo validado por MacParakeet; venta directa evita el 30% en Mac.

## D11 — Estrategia iOS: grabadora presencial + companion (constraint duro)

**Decisión:** iOS/iPadOS **no puede capturar audio del sistema de otras apps** (sandbox; sin process taps; ninguna API graba llamadas de terceros — la grabación de llamadas de iOS 18.1+ es exclusiva de la app Teléfono). El producto iOS es: (1) grabadora presencial de primera clase (AirPods studio-quality vía `bluetoothHighQualityRecording`, iOS 26); (2) llamadas por altavoz (mic captura ambos lados); (3) ReplayKit broadcast solo como importador experimental (límite duro 50 MB en la extensión → escribir a App Group, procesar en la app); (4) importador universal (share extension); (5) companion de la Mac (CKSyncEngine, Live Activities, control remoto); (6) procesamiento nocturno (BGProcessingTask con `requiresExternalPower`).
**Porqué:** prometer captura de llamadas en iOS sería mentir; el reposicionamiento cubre casos reales que la Mac no cubre.

## D12 — Compartir: escalera de 3 niveles, schema listo desde v1

**Decisión:** L0 (M5): share sheet + export MD/PDF + **GitHub Gist** con un click. L1 (M7, PRO): CKShare nativo entre Apple IDs. L2 (fase 5): relay self-hostable estilo PocketBase (patrón Humla) con visor web de snapshots de solo lectura. No se construye backend propio antes de L2, pero el schema (D4) ya lo soporta.
**Porqué:** cada nivel es útil solo; cero servidores hasta que haya demanda probada.

## D13 — Testing: XCTest (no Swift Testing) y build sin Xcode completo

**Decisión:** XCTest para toda la suite; CI con `swift build && swift test` en `macos-latest`.
**Porqué:** la máquina de desarrollo tenía CommandLineTools seleccionado (sin módulos Testing/XCTest); XCTest + `DEVELOPER_DIR` es el mínimo común. Migrar a Swift Testing es aceptable cuando deje de doler.

## D14 — Concurrencia: Swift 6 estricto

**Decisión:** actors + `AsyncStream` end-to-end; `@unchecked Sendable` solo con comentario que justifique el confinamiento; sin locks manuales.
**Porqué:** elimina por construcción la clase de bugs que en Meetily viven en 83 bloques `unsafe` y 266 `unwrap()`.

## D15 — STT M2: FluidAudio pineado por minor + Parakeet v3 pineado por sha256 multi-artefacto

**Contexto:** M2 necesita STT vivo y batch on-device (D7). Los modelos CoreML se distribuyen como bundles `.mlmodelc` (directorios de N archivos) en repos de Hugging Face — un solo `sha256` por modelo no alcanza.
**Decisión:** (1) FluidAudio como dependencia SPM con `.upToNextMinor(from: "0.15.4")` — renombra API pública entre minors. (2) El registry (`ModelDescriptor`) lista **cada archivo** como `ModelArtifact {path, sha256, sizeBytes}` con `resolveBase` fijado a un commit exacto (`…/resolve/<sha>`); `ModelStore` verifica tamaño + sha256 de cada descarga antes del move atómico, y `verify()` re-hashea todo antes de cargar. (3) Solo se descarga el subset que el loader v3 int8 usa (Preprocessor/Encoder/Decoder/JointDecisionv3 + vocab = 483 MB, no los 3 GB del repo). Los sha256 salen del tree API de HF (LFS trae sha256; los archivos chicos se hashean a mano al pinear).
**Regla crítica descubierta:** `folderName` del descriptor DEBE ser el nombre que FluidAudio resuelve (repo sin `-coreml`, p. ej. `parakeet-tdt-0.6b-v3`); con cualquier otro nombre FluidAudio **re-descarga el repo sin verificación** a un directorio hermano, bypasseando el registry. Protegido por test.
**Porqué:** cumple la regla "modelos = código" (verificación obligatoria) sin renunciar al loader de FluidAudio; el pin por commit hace la descarga irreproducible imposible. Licencias: FluidAudio Apache-2.0, modelo CC-BY-4.0 — compatibles con MIT + atribución (D3).

## D16 — Captions vivas: sliding window corta sobre TDT v3 + filtro de deltas propio

**Contexto:** el config `.streaming` de FluidAudio emite un update por chunk de 11 s (su `hypothesisChunkSeconds` no se usa en el pipeline 0.15.4) — inservible para el criterio M2 de < 2 s. Las alternativas de streaming real (Parakeet EOU 120M, Nemotron) usan modelos más chicos/otros repos y duplicarían el trabajo de registry para peor calidad.
**Decisión:** quedarse en TDT v3 con `SlidingWindowAsrConfig` custom: left 11 s / chunk 1.0 s / right 0.4 s (= 12.4 s, cabe en los 15 s fijos del modelo). El left context largo sostiene la calidad; la latencia estructural queda en chunk + right + inferencia. Como el dedup upstream falla con chunks pequeños (cada update re-emite el left context re-decodificado), `ParakeetSegmentMapper` corta el overlap del lado nuestro: los `tokenTimings` llegan en tiempo absoluto del stream → se conservan solo los tokens con `startTime` posterior al último borde emitido y el texto del delta se reconstruye de esos tokens.
**Medido (M4 Max, con batch a ~100x en paralelo):** transcript lag p50 0.24 s / p95 0.53 s. Costo aceptado: los deltas pueden cortar subwords en las costuras ("ally, on your device") — el transcript de calidad sale del re-pase final (D7), las captions priorizan frescura.
**Porqué:** un solo modelo para vivo+batch en M2 (menos RAM, un registry), cumpliendo el criterio con margen 4x.

## D17 — Diarización M3: pyannote+WeSpeaker online, threshold 0.45 calibrado, atribución estructural con slicing multi-turno

**Contexto:** M3 necesita who-said-what sobre el canal system. FluidAudio trae el par pyannote community-1 (segmentación) + WeSpeaker v2 (embeddings) en un repo CoreML de ~14 MB, con un pipeline online (`DiarizerManager`) cuyo `SpeakerManager` mantiene identidades estables entre ventanas — apto para streaming con `atTime`.
**Decisión:** (1) Par pyannote+WeSpeaker pineado por sha256 (10 artefactos, commit `1ed7a662…`) en el mismo `ModelStore` (D15); carga por paths explícitos (`DiarizerModels.load(localSegmentationModel:…)`), que jamás descarga. (2) **`clusteringThreshold = 0.45`**, no el 0.7 default de FluidAudio: su wiring interno multiplica ×1.2 (→ 0.84 de distancia coseno de asignación) y fusiona speakers reales — verificado con el sample AMI de pyannote (RTTM de referencia), que 0.7 y 0.55 colapsan a 1 speaker y 0.45 reproduce casi exacto. (3) Atribución estructural en `SpeakerAttributor` (pure functions): mic → "Me" por hardware (D5, sin ML); system → turno con mayor overlap; segmentos que cruzan varios turnos se **parten en los límites de los turnos** repartiendo palabras proporcionalmente al tiempo; sin turno → sin atribuir (mejor que mal atribuido). (4) Los segmentos batch cortan por puntuación de oración además de pausas, porque los timings TDT no traen gaps (fin de token = inicio del siguiente) y el corte por pausa casi nunca dispara.
**Medido (2026-07-07):** AMI sample 2 speakers ≈ RTTM de referencia; conversaciones TTS de 2 voces alternan correctamente (artefacto conocido: un speaker espurio en la última ventana zero-padded, quality ~0.2). Un diarizer = una sesión (el `SpeakerManager` acumula la base de voces).
**Porqué:** mismo stack y mismo registry que M2; el threshold es la única desviación del default upstream y está anclado a un ground truth público reproducible. Pendiente del criterio formal: DER < 15% en reunión real de 4 personas.

## D18 — Resúmenes M4: Foundation Models on-device con map-reduce convergente; BYOK explícito OpenAI-compatible

**Contexto:** M4 pide resúmenes estructurados < 30 s, bilingües ES/EN con glosario intacto. El modelo on-device de Apple (Foundation Models, macOS 26+) tiene ventana de **4096 tokens contando instrucciones, schema de guided generation y salida**.
**Decisión:** (1) Default absoluto: `FoundationModelSummaryProvider` on-device con guided generation (`@Generable`) hacia un `StructuredSummary` neutro que comparten todos los providers (markdown + owners de action items se derivan de ahí). (2) Transcripts largos van por **map-reduce recursivo**: chunks de 4500 chars → notas con tope duro de 250 tokens (compresión ≥4x por nivel — el tope es lo que garantiza convergencia; sin él las notas no encogen y la recursión no termina); el pase final estructurado exige material ≤ 3000 chars porque su ventana también carga el schema y la salida. (3) Decodificación **greedy** en todos los pases: con sampling el modelo de 3B inventaba action items. (4) La directiva de idioma va con nombre humano ("Spanish (español)", no "es") y se REPITE al final del prompt de usuario — solo en instructions el modelo la ignoraba. Los headings se traducen; el glosario queda verbatim. (5) Los action items solo existen en el campo dedicado (nunca como sección) y la guía exige compromisos explícitos, array vacío si no hubo. (6) BYOK: `OpenAICompatibleSummaryProvider` (`/chat/completions`, JSON al `StructuredSummary`), siempre opt-in visible y etiquetado (D8); en el CLI la key llega por `PORTAVOZ_BYOK_API_KEY` (el almacenamiento Keychain llega con la app).
**Medido (M4 Max, 2026-07-07):** resumen ES de reunión EN con glosario intacto en 3.8 s; transcript de 3 ventanas por el path incremental en ~11 s. Criterio < 30 s con margen.
**Porqué:** privacidad por defecto real (nada sale del dispositivo), y las cuatro lecciones de prompting/presupuesto quedan fijadas por tests (unit + integración gated).

## D19 — StorageKit M5: el contrato D4 ejecutado en GRDB 7 + FTS5

**Contexto:** primer código de persistencia real; D4 fijó el contrato desde M0.
**Decisión:** GRDB 7 (`upToNextMajor(from: 7.11.1)`). Tablas singulares camelCase (`meeting`, `speaker`, `segment`, `summary`, `actionItem`) alineadas 1:1 con records Codable. Ejecutando D4: UUID string PKs en todo; `updatedAt` en cada write (con `createdAt` preservado en upserts) + `deletedAt` tombstone (nunca hard delete — `delete()` marca, los queries filtran); summaries **solo se insertan** con `version` autoincremental por (meeting, recipe) y unique key — los **action items son la excepción mutable deliberada** (el usuario los marca hechos) y viven en su propia tabla referenciando el snapshot; `audioDirectory` relativo con rechazo de paths absolutos y `..` al guardar; `visibility` reservado con default "private". FTS5 en tabla externa (`segmentSearch`) sincronizada por triggers de GRDB; el MATCH del usuario se sanitiza citando cada token (input hostil probado en tests). `AudioRetentionPolicy` se persiste como JSON y **`enforceAudioRetention` cierra la deuda de M1**: borra el audio expirado bajo el root (con guard anti path-traversal), limpia la referencia y jamás toca transcript. Tipos de dominio movidos a Core para evitar deps Kit↔Kit: `Meeting` (nuevo), `AudioRetentionPolicy` (desde AudioCaptureKit, typealias de compat), `Recipe`/`SummaryDraft`/`ActionItem` (desde IntelligenceKit).
**Diferido explícito:** sqlite-vec espera a M8 (extensión C; nada antes del RAG lee vectores).
**Porqué:** validado en producción por MacParakeet/Humla (D4); el esquema queda sharing-ready sin migración dolorosa y el CLI ya persiste/busca reuniones reales (`summarize --save`, `meetings list|show|search`).

## D20 — App shell macOS: target SPM + script de bundle, sin proyecto Xcode (por ahora)

**Contexto:** M5 necesita el primer target de UI. Un `.app` con permisos TCC (micrófono + grabación de audio del sistema) normalmente empuja hacia un proyecto Xcode.
**Decisión:** `portavoz-app` es un `executableTarget` SPM normal (SwiftUI + Observation, todo el trabajo pesado en los Kits) y `scripts/make-app.sh` lo envuelve en `dist/Portavoz.app`: Info.plist con `NSMicrophoneUsageDescription` + `NSAudioCaptureUsageDescription`, bundle id `app.portavoz.mac`, mínimo macOS 14.4, firma ad-hoc. Sin `.xcodeproj` ni XcodeGen hasta que algo lo fuerce — los candidatos conocidos son iOS (M7), Sparkle/notarización (empaquetado final de M5) y assets/entitlements complejos. Migrar después es barato: los archivos SwiftUI se mueven tal cual a un target de app Xcode.
**Estructura de la app:** `AppServices` (composition root en MainActor: `MeetingStore` + engines cargados una vez) → `NavigationSplitView` con `LibraryView` (lista + búsqueda FTS), `MeetingDetailView` (transcript con **speaker pills editables** — cierra el pendiente de M3 —, snapshot de resumen, action items chequeables) y `RecordingView`/`RecordingController` (máquina de estados: preparar modelos → captions vivas por canal → al detener: diarizar system.wav → atribuir → persistir → resumen FM si hay Apple Intelligence). `MarkdownLite` renderiza los resúmenes hasta el pase de polish.
**Verificado (2026-07-07):** el bundle compila, firma, lanza y renderiza; una reunión guardada por el CLI aparece en la biblioteca de la app (mismo SQLite). El flujo de grabación in-app queda pendiente de prueba interactiva (TCC pide permisos la primera vez).
**Porqué:** mantiene `swift build`/`swift test` como único flujo (D13), el repo 100% texto, y el harness de desarrollo (humano o agente) puede construir y verificar la app headless.

## D21 — Identidad M6: voiceprint cifrado con "Me" cross-canal + nombres solo con prueba verificada

**Contexto:** M6 pide reconocer al usuario más allá del canal mic (reuniones híbridas donde su voz llega por sala/system) y el mapeo 1-tap de speakers a nombres.
**Decisión (voiceprint):** el enrolamiento extrae un embedding WeSpeaker de 256 dims (`extractSpeakerEmbedding`) de ~12 s de voz sola — el audio fuente no se conserva. `VoiceprintStore` lo cifra AES-GCM con llave de 256 bits que vive SOLO en el Keychain (`WhenUnlockedThisDeviceOnly`): archivo sin llave = ilegible por construcción; `delete()` destruye archivo y llave en una acción (D8: biométrico, on-device, nunca sync, borrable). El diarizador lo registra vía `initializeKnownSpeakers` con id reservado `me`/`isPermanent` → sus turnos salen con label "Me" y `SpeakerAttributor` los funde con el "Me" estructural del mic en un solo `Speaker`.
**Decisión (nombres):** `SpeakerNamer` (FM, greedy) propone label→nombre SOLO con prueba del transcript (auto-presentación o ser nombrado alrededor de su turno), con regla de oro **never trust, verify**: toda sugerencia cuyo nombre no aparezca literalmente en el transcript se descarta en código — el test de integración cazó al 3B inventando "John" con evidencia fabricada pese al prompt. Nada se auto-aplica: chips "S1 → ¿Carolina?" con evidencia en tooltip, un tap para aceptar (criterio M6).
**Verificado (2026-07-07, TTS + modelos reales):** Samantha enrolada desde clip solo → sus turnos en conversación de 2 voces vuelven 100% como "Me" (CLI y test gated); namer encuentra "Carolina" auto-presentada y, tras el filtro, ya no inventa nombres para quien nunca se nombró.
**Porqué:** identidad estructural donde el hardware alcanza (D5) + biometría opt-in donde no; y con modelos chicos, la validez de una afirmación se verifica fuera del modelo, no se le pide por favor.

## D22 — RAG local M8: NLContextualEmbedding cross-lingüe, BLOB + coseno, retrieval afinado sobre fallas reales

**Contexto:** M8 pide que un agente responda "¿qué acordé ayer?" sobre una biblioteca bilingüe ES/EN, 100% local.
**Decisión (índice):** embeddings por segmento con **`NLContextualEmbedding` (script latino)** — un solo modelo del OS, un solo espacio vectorial para español E inglés (verificado: la paráfrasis cross-lingüe queda más cerca que texto no relacionado). Mean-pooling + normalización L2. Persistencia: columna BLOB en `segment` (schema v2) + coseno brute-force en memoria — a escala de reuniones son milisegundos; sqlite-vec entra cuando los números lo pidan (D19). Los embeddings sobreviven re-saves sin cambios, se invalidan al editar texto, y las reuniones tombstoned salen del índice.
**Decisión (retrieval, cada regla nace de una falla observada):** (1) el query léxico de una PREGUNTA usa OR de palabras-contenido (≥4 chars) — el AND token-a-token jamás matchea un transcript, y el OR con stopwords matchea todo lo del mismo idioma; (2) **multi-query con FM**: la pregunta se parafrasea a ambos idiomas de la biblioteca (recall cross-lingüe; sin FM, degrada a la pregunta sola); (3) los **micro-segmentos (< 20 chars) se excluyen del índice semántico** (marcador vacío) — ruido del mismo idioma ahogaba la señal cross-lingüe; (4) fusión por reciprocal rank (k=60). Respuesta: `RAGAnswerer` on-device, greedy, oraciones completas con citas [n], solo-contexto-o-decirlo.
**Verificado (2026-07-07):** `portavoz-cli ask` y la tool MCP `ask` responden con fuentes correctas en ambos sentidos de idioma; **criterio de aceptación M8 cumplido** vía sesión MCP real.
**Porqué:** cero dependencias de terceros para el índice, bilingüe de nacimiento, y cada heurística tiene un caso de fallo que la justifica — no son supersticiones de RAG.

## D23 — Empaquetado M5: Sparkle 2 embebido por script, DMG + appcast + cask de un solo comando

**Contexto:** D10 fijó el canal: DMG notarizado + Sparkle + Homebrew cask. La app es un ejecutable SPM empaquetado por script (D20), así que el empaquetado también es 100% script.
**Decisión:** (1) **Sparkle 2.9+** como dep SPM del target de la app (`SPUStandardUpdaterController` + menú "Buscar actualizaciones…"); `make-app.sh` embebe `Sparkle.framework` en `Contents/Frameworks`, añade el rpath `@executable_path/../Frameworks`, firma los XPC/Autoupdate internos y escribe `SUFeedURL` (appcast en el release de GitHub) + `SUPublicEDKey`. (2) **Llave EdDSA dedicada** en el Keychain bajo el account `portavoz` (NO la default — esta máquina ya tenía una de otro proyecto); la pública vive en `assets/sparkle-public-key`; `generate_appcast --account portavoz` firma cada release. (3) `make-dmg.sh`: bundle release → DMG UDZO con symlink a /Applications; firma ad-hoc por defecto, `PORTAVOZ_SIGN_IDENTITY` y `PORTAVOZ_NOTARY_PROFILE` (notarytool + staple) para distribución real. (4) `make-release.sh <version>`: estampa versión, DMG, appcast firmado y cask (`packaging/portavoz.rb` con placeholders) → `dist/release/` listo para `gh release create`; checklist de publicación en el header del script.
**Verificado (2026-07-07, ad-hoc E2E):** app con Sparkle embebido lanza (rpath ✓); `make-release.sh 0.1.0` produjo DMG de 7.9 MB montable (los modelos se descargan bajo demanda — instalador liviano), appcast con `edSignature` y cask con versión+sha256 reales.
**Completado (10 jul 2026):** Developer ID + notarización (`portavoz-notary`), repo público, y cask en el tap centralizado `johnny4young/homebrew-tap`.
**Porqué:** el pipeline entero de release es un comando reproducible sin Xcode; lo único no automatizable son las credenciales de Apple.

## D24 — Cancelación de eco (AEC) por defecto en el canal mic

**Contexto:** en una reunión real reproducida por parlantes, el mic captó el audio del sistema por el aire: ~100% del canal "Yo" era eco de los demás participantes, duplicando el transcript y rompiendo la premisa mic→Me (D5). Suprimirlo por texto solo detecta ~57% (el eco llega degradado y se transcribe distinto). El usuario rechaza explícitamente que se le obligue a usar audífonos (Meetily lo resuelve bien).
**Decisión:** `MicrophoneSource` activa **voice processing de Apple** (`setVoiceProcessingEnabled(true)`, AEC del sistema contra la salida por defecto) **por defecto**, con `voiceProcessingOtherAudioDuckingConfiguration` en `.min` para no atenuar el audio de la reunión. Opt-out: toggle "Cancelación de eco" en Ajustes (`aecEnabled`) y `record --no-aec`. Si el dispositivo rechaza voice processing, se degrada a captura cruda sin fallar. En la misma capa: resiliencia a `AVAudioEngineConfigurationChange` (cambio de dispositivo mid-recording) con reinstalación del tap, resampleo lineal al rate original del stream y relleno del hueco con silencio — el canal jamás muere en silencio ni desalinea la timeline.
**Verificado (2026-07-07):** smoke test CLI (engine arranca con VPIO, WAV escrito). Campo pendiente: reunión real con parlantes (el "Yo" no debe duplicar a los demás) y switch de audífonos a mitad de grabación.
**Porqué:** el fix físico (el mic deja de contener a los demás) arregla a la vez el "Yo" fantasma, la duplicación del transcript, y el sesgo del resumen — sin imponer hardware al usuario.

## D25 — Motores plurales por rol con recomendación por hardware (operacionaliza D7)

**Contexto:** hoy el routing por tarea (D7) tiene un solo motor por rol: Parakeet (vivo), Whisper large-v3-turbo (calidad), Foundation Models (resúmenes, exige macOS 26 + Apple Intelligence) + BYOK. Tres presiones de mercado: (1) Apple liberó `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26) — más rápido que Whisper en benchmarks públicos, cero descarga, y es el motor del sherlocking (Notes); (2) Meetily/humla/MacParakeet ofrecen elección de modelo como feature central (humla incluso rutea por idioma); (3) la crítica #1 a Meetily es la barrera de hardware — un Mac sin Apple Intelligence hoy se queda sin resumen local.
**Decisión:** cada rol acepta motores plurales con un **recomendador por hardware** (chip/RAM/versión de macOS) y default automático visible ("Recomendado para tu Mac"):
- **ASR vivo**: Parakeet TDT v3 | **SpeechAnalyzer streaming** (verificado 2026: `AsyncSequence` con `volatileResults`, finalización ~2.1 s, es_MX/es_US soportados) — competencia real en el rol VIVO, benchmarkear ambos.
- **ASR calidad (refine)**: Whisper large-v3-turbo manda — **verificado que SpeechAnalyzer NO es clase-calidad**: WER 14.0% en conversación (earnings22, Argmax) ≈ Whisper base/small, sin vocabulario custom, sin diarización, ~22 idiomas. Queda como refine "rápido y suficiente" en iOS/Macs sin disco, jamás default. Cuantizadas verificadas en argmaxinc/whisperkit-coreml: `large-v3-v20240930_547MB` y `_626MB` (esta última recomendada por Argmax para accuracy multilingüe — candidata para es/en con poco disco). Bonus verificado: Argmax OSS SDK v1.0 (may 2026) incluye **SpeakerKit** (diarización) en el mismo paquete que ya usamos — alternativa/benchmark vs FluidAudio.
- **LLM (resumen/notas/nombres/companiono)**: cadena con fallback explícito y visible — Foundation Models on-device → **MLX embebido** (decidido tras verificación 2026: `mlx-swift-lm` es MIT, SPM nativo, 1.4–1.8× más rápido que llama.cpp en 3–4B con Metal, ~2–2.5 GB de RAM en q4; llama.cpp no tiene SPM first-party) → BYOK OpenAI-compatible (ya cubre Ollama/LM Studio/Groq/OpenRouter — documentarlo en la UI, es feature escondida). Camino incremental: integración Ollama de primera clase ANTES que el embebido (la plomería BYOK ya existe; embeber MLX es fase posterior si hay demanda de cero-dependencias).
- Overrides **por reunión y por idioma** (patrón humla), nunca un modelo global (D7 se mantiene).
- Todo motor descargable pasa por el registry sha256 (D15); los engines cumplen los protocolos existentes (`SummaryProvider`, transcripción por rol).
- **Parámetros de referencia (medidos por Meetily, validar en M10)**: LLM local qwen-class 2b (<14 GB RAM) / 4b (≥14 GB); catálogo Whisper con variantes cuantizadas q5 (turbo q5_0 ≈ 547 MB — clave para Macs con poco disco y para iOS); caché de resumen por fingerprint (transcript+recipe+modelo+params) para no regenerar gratis; **resumen pivote en EN cacheado + re-traducción bajo demanda** — nuestro caso bilingüe lo agradece el doble.
**Porqué:** la elección de modelo es la feature que el usuario percibe como "control"; la recomendación automática es lo que evita que se convierta en fricción. SpeechAnalyzer convierte la amenaza de Apple en proveedor gratuito.

## D26 — Companion en vivo: detección de preguntas + respuesta sugerida

> **Nombre (jul 2026):** el feature se llama **Companion**. Se renombró desde "Copiloto" — "Copilot" carga baggage de GitHub/Microsoft y "Facilitator" será el nombre del feature equivalente de Teams (~ago-sep 2026). Símbolos, UI y docs usan "Companion".

**Contexto:** pedido fundador — si en la reunión preguntan algo ("¿cuál es la diferencia entre `var` y `let`?"), el sistema debe ofrecer la respuesta en tiempo real. Jamie valida el patrón (sidebar Q&A en vivo); nadie lo hace on-device.
**Decisión:** pipeline de 3 etapas sobre las captions cerradas (el coalescer ya define "cerrada"):
1. **Detección** (cada tick, barato): heurística (¿termina en "?", contiene interrogativos, prosodia del texto?) como pre-filtro → FM greedy con schema `{esPregunta, pregunta, dirigidaAMí, tipo: conocimiento|contexto|logística}` sobre la ventana reciente. El detector de "te preguntaron algo" (mención de tu nombre) comparte esta etapa.
2. **Respuesta según tipo**: `contexto` (¿qué dijimos del budget?) → RAG local existente (D22) sobre la reunión en curso + historial; `conocimiento` (var vs let) → FM on-device primero; si el usuario configuró BYOK **y activó "Companion con BYOK"**, se usa el proveedor externo — con disclosure permanente en la tarjeta ("respondido por <proveedor>"). Solo sale del dispositivo el texto de la pregunta + contexto mínimo, nunca audio (D8).
3. **UI**: tarjeta discreta en el panel derecho de grabación ("❓ Preguntaron: … → 💡 Respuesta sugerida"), acciones copiar/descartar/fijar. Nunca auto-responde ni auto-habla; opt-in por reunión (toggle junto al de traducción). Presupuesto: detección <1 s por tick, respuesta <5 s.
**Porqué:** es el momento "wow" en vivo con la arquitectura que ya existe (captions cerradas + FM + RAG); la etapa de tipos evita el fallo clásico (responder trivialidades logísticas).
**Contexto de mercado (verificado 2026-07)**: NADIE en meeting-notes tiene detección pasiva de preguntas — Cluely la vende y falla (5–10 s reales medidos por reviewers, estigma de "cheating tool", $20–75/mes); Otter es invocación explícita por voz; Granola/Jamie son pull manual. **Microsoft lanza "Facilitator" en Teams (detección proactiva de preguntas) hacia ago–sep 2026** — validación y reloj a la vez. Nuestro framing gana por diseño: local (latencia on-device puede cumplir <5 s donde Cluely no), transparente (te ayuda a TI con tus datos, sin modo "indetectable"), y el tipo `contexto` responde desde TU historial — cosa que nadie sin biblioteca local puede hacer.

## D27 — El audio es actor de primera clase

**Contexto:** hoy el audio se captura, se transcribe y queda muerto en disco: la app no lo reproduce. Humla tiene playback con highlight palabra a palabra; Otter/Granola tratan el audio como el registro canónico. Sin playback no hay verificación humana del transcript ("¿de verdad dijo eso?") ni clips.
**Decisión:** AudioPlaybackKit (nuevo Kit, depende solo de PortavozCore):
- **Player sincronizado**: AVAudioEngine playerNode sobre los WAV existentes; click en un segmento salta al timestamp (los `startTime` ya existen); durante la reproducción se resalta el segmento actual (y palabra, cuando el engine da word timings). Velocidad 1–2x y skip-silencio (los gaps entre segmentos son conocidos).
- **Waveform** por reunión: RMS downsampleado a ~2000 buckets, coloreado por speaker (turnos de diarización), cacheado en `Audio/<id>/waveform.bin` — se computa una vez al guardar.
- **Clips**: marcar rango en la waveform/transcript → exportar `.m4a` (AVAssetExportSession) + snippet MD con atribución; "marcar" FREE, "exportar" PRO (ya en la matriz).
- **Master + economía**: WAV sigue siendo master (pipeline lo exige); transcode opcional a AAC tras el refine como política de retención adicional (D4 ya modela retención).
- **Acondicionamiento de señal** (patrón Meetily): normalización a −23 LUFS (estándar broadcast de voz) como target del pipeline — nuestro `normalizePeak` es el primer paso; evaluar RNNoise-style denoise (Apple ya aporta AEC+NS vía voice processing, D24) y high-pass ~80 Hz para voz.
- **Import de audio externo como reunión** (arrastrar un .m4a/.wav a la biblioteca → transcribe+diariza+resume): el pipeline del refine ya lo hace todo; solo falta la puerta de entrada en la UI.
- **Crash-safety del registro** (patrón MacParakeet, verificado en su spec): sus M4A fragmentados a 1 s sobreviven `kill -9`. Nuestros WAV vía AVAudioFile probablemente NO (header RIFF incompleto en crash) — verificar y migrar el contenedor a **CAF** (append-safe por diseño, mismo AVAudioFile) o M4A fragmentado. Una grabación de 1 h no puede morir con la app.
- **Economía de storage**: 22 min = 126 MB/canal en WAV; MacParakeet guarda AAC 64 kbps (~10 MB). Mantener PCM hasta el refine y transcodificar después es el balance (el refine quiere señal íntegra).
- **⚠️ Riesgo verificado a vigilar**: MacParakeet DESCARTÓ los process taps porque "no coexisten confiablemente con VPIO in-process" — exactamente nuestra combinación D6+D24. Nuestra evidencia (1 reunión real con ambos activos) es insuficiente. Plan B documentado: cancelación de eco OFFLINE post-grabación (derivar mic-cleaned con estimación de delay), que es lo que ellos hacen.
**Porqué:** el audio es la fuente de verdad del producto; tratarlo como archivo muerto regala la experiencia diferencial a Otter. Todo es AVFoundation puro — cero dependencias nuevas.

## D28 — Notas de coautoría: el loop de Granola sobre ContextFeedKit

**Contexto:** el patrón más validado de la categoría es el de Granola ($1.5B de valuación, mar 2026): el usuario escribe notas crudas durante la reunión y la IA las teje con el transcript — "las notas llevan la intención, el transcript lleva los hechos". Ese principio está LITERALMENTE escrito en el doc de nuestro `ContextItem` (ContextFeedKit) desde M0… y el tipo sigue huérfano: sin storage, sin UI, sin integración al resumen. El roadmap v2.0 no lo programó — error corregido aquí.
**Decisión:** milestone propio y temprano en la fase 2:
1. **Editor de notas en RecordingView** (tercer panel/tab junto a captions y resumen — patrón del panel Notes/Transcript/Ask de MacParakeet): texto plano con timestamps automáticos por línea (`ContextItem.timestamp` = segundos desde el inicio, ya modelado). Links y snippets pegados se tipan solos (`kind`).
2. **Persistencia**: tabla `contextItem` (aditiva, D4-compatible) + export en el markdown.
3. **Resumen guiado por notas**: `SummaryRequest` gana `contextItems`; PromptFactory los inyecta como intención del usuario ("estas notas marcan lo que importa — expándelas con hechos del transcript, no las contradigas"). El mid-meeting "¿qué me perdí?" y el rolling summary también las ven.
4. **Distinción visual de coautoría** (el detalle que hace confiable a Granola): en el resumen final, lo que vino de tus notas se marca distinto de lo que añadió la IA, y las adiciones enlazan al segmento del transcript (las citas con timestamp ya existen en el schema).
**Porqué:** convierte el resumen genérico en TU nota — el diferenciador citado en todas las reviews de Granola — con un tipo que ya diseñamos y un patrón de prompt que ya domina el pipeline (glosario/idioma). Bonus de mercado: las críticas #1 a Granola (sin speaker ID, sin playback, consent) son exactamente D21+D27+D8 — su loop más nuestra identidad es una combinación que nadie tiene.

## D29 — Un solo vuelo al modelo on-device: scheduler de prioridades

**Contexto:** el FM de 3B es UN recurso compartido — resumen rodante, Companion (D26), nombres, `ask` y re-resúmenes del refine lo quieren a la vez, y el ANE serializa la generación de todos modos: pedidos concurrentes solo entierran la cola dentro del daemon, donde no se puede gestionar. Sin política, el presupuesto de <5 s del Companion es lotería (T3 de GAPS).
**Decisión:** `IntelligenceScheduler` (actor en IntelligenceKit, sin dependencia de FM — testeable en cualquier plataforma): cola de prioridad single-flight con tres clases — `interactive` (un humano espera: respuestas del Companion, nombres, ask) > `live` (ticks de detección de preguntas: frecuentes, baratos, descartables) > `background` (notas del resumen rodante, re-resúmenes). Reglas: (1) **granularidad = UNA llamada al modelo** — las cadenas map-reduce sueltan el slot ENTRE llamadas, así lo interactivo se intercala y su espera queda acotada por la llamada en vuelo (~1–4 s); (2) FIFO dentro de la misma clase; (3) **latest-wins por `key`**: un job encolado con la misma key es reemplazado con `CancellationError` (los ticks de detección jamás se apilan) — lo EN VUELO nunca se interrumpe; (4) cancelación del caller desencola. Cableado: los 6 call sites del FM pasan por el scheduler; los métodos públicos del provider ganan `priority:` (default `.interactive`; el resumen rodante pasa `.background`). Nota Swift 6: `Response<T>` de FM no es Sendable — los closures devuelven el payload (String/tipos propios) construido DENTRO del slot.
**Porqué:** convierte la latencia del Companion de impredecible a acotada por diseño, con 7 tests puros que fijan las propiedades (single-flight, prioridad, FIFO, latest-wins, cancelación, release en throw, intercalado entre pasos de cadena).

## D30 — XcodeGen + XCUITest para verificación de UI (matiza D20)

**Contexto:** D20 mantiene el shell macOS como target SPM + `make-app.sh`, sin proyecto Xcode. Pero verificar la UI a mano (o peor, con control-de-pantalla tipo computer-use) es lento y frágil; XCUITest necesita un proyecto Xcode con un target `bundle.ui-testing`. El proyecto hermano Gancho ya resolvió esto con **XcodeGen** (`project.yml` como fuente de verdad, `.xcodeproj` generado y gitignored).
**Decisión:** adoptar el mismo patrón SOLO para tooling de verificación. `project.yml` genera `Portavoz.xcodeproj` (gitignored) con dos targets: `Portavoz` (app, recompila `Sources/portavoz-app` contra los productos-librería del package) y `PortavozUITests` (`bundle.ui-testing`, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`, `GENERATE_INFOPLIST_FILE: YES` para que Xcode firme el runner — Gatekeeper bloquea runners sin firmar). La app honra launch-args de testing: **`-use-temp-store`** (DB desechable, jamás toca la biblioteca real) y **`-seed-demo`** (siembra una reunión determinística con transcript, resumen, bullet de coautoría "▸" **y audio** — `AppServices.seedDemoIfRequested()`). El audio se aísla vía la env **`PORTAVOZ_AUDIO_ROOT`** (raíz de audio relocatable, sin tocar tu carpeta): el seed sintetiza un clip de dos tonos (mic 220 Hz / system 440 Hz, medio y medio → el waveform muestra ambos colores) o **adopta una grabación real** si ya hay una en la raíz — un UITest apunta `PORTAVOZ_TEST_AUDIO_ROOT` a una copia real para ejercitar el player sobre audio de verdad (verificado: 8 min reales, player + waveform OK). `make test-ui` corre `xcodebuild test`. Firma ad-hoc (`CODE_SIGN_IDENTITY: "-"`, sin team, hardened runtime off) — es tooling local, no distribución.
**Porqué:** verificación de UI reproducible y automatizada sin conducir la pantalla. **El shipping sigue siendo `make-app.sh`** (firmado + notarizado, D20/D23 intactos); este proyecto es solo para `make test-ui` y no es el camino de release. XCTest en el target de UI convive con la suite de paquete XCTest (D13). Verificado: `LibraryUITests` (la biblioteca renderiza) y `MeetingDetailUITests` (transcript + resumen + marca ▸ de coautoría D28) en verde.

## D31 — IntegrationsKit es la única capa cross-Kit (jul 2026)

**Contexto:** el pipeline de RAG (`AskPipeline`) necesita StorageKit (store/FTS/vectores) e IntelligenceKit (embedder, expansión de query) a la vez; vivía duplicado en CLI y app porque ningún Kit podía depender de ambos.

**Decisión:** IntegrationsKit es el único Kit autorizado a depender de Kits hermanos (IntelligenceKit + StorageKit). Es la capa de integraciones transversales sobre reuniones guardadas (export, retrieval RAG, calendario). El resto de Kits siguen dependiendo solo de Core. `AskPipeline` vive una sola vez ahí; CLI y app lo consumen.

## D32 — MLX embebido vive en IntelligenceKit (jul 2026)

**Contexto:** D25 pedía un motor de resúmenes 100% local para Macs sin Apple Intelligence NI Ollama. El provider embebido necesita el stack de prompts/parsing (`PromptFactory`, `StructuredSummary`, `SummaryFingerprint`) que vive en IntelligenceKit; un Kit aparte habría obligado a mover todo eso a Core.

**Decisión:** `mlx-swift-lm` (MIT, pineado exact 3.31.4 — sucesor oficial de `mlx-swift-examples`, que quedó congelado en oct 2025; la migración se hizo en jul 2026 para soportar `qwen3_5`) es dependencia directa de IntelligenceKit, junto con `swift-transformers` (el paquete nuevo desacopló el tokenizer: la app lo provee vía las macros de `MLXHuggingFace`) y `MLXSummaryProvider` vive allí, reusando el contrato prompt/JSON del provider OpenAI-compatible (cambiar de motor jamás cambia la forma del resumen). Modelo por defecto: **Qwen3-4B-Instruct-2507 4-bit** (Apache-2.0, sin gate, ~2.3 GB), sha256-pineado en `ModelCatalog` al commit exacto (D7). La generación corre en GPU vía `ModelContainer.perform` (serializada, un resumen a la vez) y NO pasa por el `IntelligenceScheduler` (ese lane existe por contención del ANE). Costo aceptado: mlx compila C++/Metal en el primer build (~10 min) y engorda el binario; el modelo solo se descarga si el usuario elige el motor "Integrado".

**Shipping y verificación:** SwiftPM CLI no puede compilar los shaders Metal (limitación documentada en el README de mlx-swift): `swift build` jamás produce `default.metallib`, así que ningún test bajo `swift test` puede ejercer la generación. El metallib sale de un pase xcodebuild one-time que `scripts/build-mlx-metallib.sh` cachea en `.build/mlx/` (cache keyed por la versión resuelta de mlx-swift; requiere el Metal Toolchain de Xcode 26: `xcodebuild -downloadComponent MetalToolchain`); `make-app.sh` copia `mlx-swift_Cmlx.bundle` a `Contents/Resources`, donde el loader de mlx lo resuelve vía NSBundle. La verificación E2E es in-app — `Portavoz.app/Contents/MacOS/portavoz-app --mlx-smoke` (mismo patrón que `--bench-live`): reunión sintética ES → resumen estructurado con decisión y action item correctos en ~5 s (M-series, modelo ya descargado).
