# Spec 04 — Inteligencia (IntelligenceKit)

Estado: implementado y verificado (resumen ES de reunión EN con glosario intacto en 3.8 s; RAG respondiendo con citas vía MCP). Decisiones: D8 (local por defecto, BYOK explícito), D18 (FM map-reduce), D22 (RAG), D26 (Companion implementado).

## Scheduler del modelo — `IntelligenceScheduler` (D29)

Actor single-flight que serializa TODA llamada al FM del proceso con prioridades `interactive > live > background`, FIFO por clase, latest-wins por `key` (para ticks descartables del Companion) y cancelación del caller. Granularidad = una llamada: las cadenas map-reduce sueltan el slot entre pasos → la espera de un job interactivo queda acotada por la llamada en vuelo (~1–4 s). Sin dependencia de FM (7 tests puros, corren en cualquier plataforma). Los métodos públicos del provider aceptan `priority:` (default `.interactive`); el resumen rodante de la app pasa `.background`. Swift 6: `Response<T>` no es Sendable → los closures devuelven payloads construidos dentro del slot.

## Resúmenes on-device — `FoundationModelSummaryProvider`

Requiere macOS 26 + Apple Intelligence activa (`unavailabilityReason()` da el motivo humano: device no elegible / AI apagada / modelo descargando).

**Presupuestos del modelo de 3B (medidos, no negociables):**
- La ventana de 4096 tokens cuenta TODO: instrucciones + prompt + schema del guided generation + salida. Material del pase estructurado ≤ ~3000 chars (`TranscriptFormatter.onDeviceReduceBudget`).
- Map-reduce recursivo: chunks de 4500 chars (`onDeviceChunkBudget`) → notas con `maximumResponseTokens: 250` (garantiza ≥4× compresión por nivel → convergencia; sin el cap, NO converge) → recursión hasta caber; profundidad máx 4.
- **Decodificación greedy siempre** (`GenerationOptions(sampling: .greedy)`): con sampling el 3B inventa action items (observado). Guías estrictas: "solo compromisos explícitos, array vacío si no hubo".
- Sesión FRESCA por chunk (las sesiones acumulan contexto y desbordan al segundo chunk).

**Guided generation**: `GeneratedSummary` (@Generable) → overview + sections (headings instruidos) + actionItems (owner por label). `StructuredSummary.draft(for:)` resuelve owners contra los Speakers por label/displayName (case-insensitive).

**APIs incrementales** (para el resumen rodante): `condenseWindow(segments…)` (una pasada map sobre SOLO lo nuevo), `condenseNotes(text…)` (colapsa la pila), `summarizeNotes(material, request:)` (pase reduce+estructurado). La app las usa así (spec 06): nota por tick de 40 s sobre filas cerradas nuevas → pila de notas → colapso a > 6000 chars → render; `LiveSummaryPolicy.shouldReplace` retiene renders < 90% del actual (monotonicidad visible).

## Idioma y glosario — `PromptFactory` (puro, testeado)

- **El 3B ignora directivas débiles**: "BCP-47 tag es" sale en inglés. Funciona: nombre humano ("Spanish (español)", `languageName(for:)` vía Locale) + repetir la orden AL FINAL del prompt de usuario.
- Glosario verbatim (términos que jamás se traducen) — llega del vocabulario del usuario y/o `--glossary`.
- La API real de FoundationModels se verifica en el `.swiftinterface` del SDK local — mejor fuente que cualquier doc.

## BYOK (D8) — `OpenAICompatibleChatClient` + `BYOKSettings` + `OpenAICompatibleSummaryProvider`

- **`OpenAICompatibleChatClient`**: cliente mínimo contra cualquier `/chat/completions` (OpenAI/OpenRouter/Groq/Ollama/LM Studio) — un system + un user entran, texto sale. `providerLabel` = host del endpoint (el nombre honesto para la disclosure: "api.openai.com" dice nube, "localhost" dice que nada salió). Request/parse estáticos y puros (testeados offline). Las llamadas cloud NO pasan por el `IntelligenceScheduler` — el single-flight existe por contención del ANE, no aplica a la red.
- **`BYOKSettings`**: endpoint y modelo en UserDefaults (`byokEndpoint`/`byokModel`); la key SOLO en Keychain (`SecretStore.byokAPIKeyService`). `client(...)` devuelve cliente listo o nil — nadie ve estado a medio configurar. `companionClient()` exige además el opt-in explícito `companionBYOKEnabled` (D26: configurar no es consentir); piezas faltantes degradan a on-device, jamás a error.
- **`OpenAICompatibleSummaryProvider`**: ahora solo posee el prompt de resumen y el contrato JSON→`StructuredSummary`; el HTTP vive en el chat client. Teje las notas del usuario (D28) igual que on-device — paridad testeada. Key por `PORTAVOZ_BYOK_API_KEY` en CLI; en la app, Keychain vía Settings.

## Motor de resúmenes plural (D25/M12) — Apple FM · Ollama local · MLX embebido · BYOK nube

`AppServices.summaryEngine` (UserDefaults `summaryEngine`: `appleOnDevice` default / `ollama`) + `configuredSummaryProvider()` → nil = Apple FM (map-reduce + scheduler + caché/pivote); Ollama = `OllamaService.summaryProvider(model:)` (un `OpenAICompatibleSummaryProvider` contra `localhost:11434/v1`, **sin API key** — Ollama la ignora, nada sale del equipo). `AppServices.summarize(_:)` centraliza: provider configurado, o FM si macOS 26, o throw. Cablea el resumen final (grabación + import) y regenerar; el **resumen rodante en vivo sigue siendo FM-only** (usa las APIs incrementales `condenseWindow`/`summarizeNotes` que Ollama no tiene). `OllamaService`: `isRunning()` (GET `/api/version`), `models()` (GET `/api/tags`, `parseModels` puro/testeado). Ajustes → "Motor de resúmenes": picker + detección + lista de modelos + **"Recomendado para tu Mac"** (`HardwareRecommender.advise(HardwareProfile)` puro: RAM + Apple Intelligence + Ollama corriendo + disco libre → motor sugerido con razones legibles + botón "Aplicar"; `AppServices.currentHardwareProfile()` lee el hardware real). **Cierra GAPS #7** (Mac sin Apple Intelligence resume 100% local); verificado E2E con gpt-oss:20b (resumen ES en 24 s) + UITest de la sección de Ajustes. Para no-Apple el caché por fingerprint aplica igual, pero el pivote de traducción es FM-only. **Override por reunión (M12)**: `configuredSummaryProvider(override:)` fuerza un motor para una reunión concreta sin tocar el default global; el menú "Regenerar" del detalle ofrece idioma (es/en) y, cuando hay elección real, el **motor alternativo** (Apple↔Ollama — solo el que NO es el default y solo si es usable aquí: Ollama con modelo configurado, o Apple con `appleSummaryAvailable`). El override fluye por la misma bifurcación (Ollama directo vs FM con caché/pivote), así que un override a Apple conserva el caché y el pivote.

**MLX embebido (D32, jul 2026)**: tercer motor `summaryEngine = "mlx"` — `MLXSummaryProvider` (IntelligenceKit) corre **Qwen3.5-4B 4-bit** (Apache-2.0, sha256-pineado en `ModelCatalog.mlxQwen35`, 3 GB; `mlxQwen3` queda en el catálogo para A/B) in-process en la GPU vía `mlx-swift-lm` (exact 3.31.4 — sucesor de mlx-swift-examples; el tokenizer lo provee `swift-transformers` vía las macros de `MLXHuggingFace`). **A/B de campo (jul 10, sprint demo refinada de 56 min / 852 segmentos)**: Qwen3-4B colapsó en loop degenerado dos veces (34k y 68k chars truncados); Qwen3.5-4B con `enable_thinking: false` (additionalContext — la familia 3.5 razona por defecto y el prompt JSON se pierde) produjo en 89 s decisiones + preguntas abiertas + 11 action items con owner en español limpio. `maxTokens` 16384 como protección pura anti-runaway. Reusa el prompt y el contrato JSON de `OpenAICompatibleSummaryProvider.prompt/parseStructured` — mismo `StructuredSummary`, mismo fingerprint. `MLXModelCache` (actor) mantiene UN `ModelContainer` cargado y serializa la generación (`container.perform`, temperatura 0); no pasa por `IntelligenceScheduler` (GPU, no ANE). Ajustes → "Built-in (MLX)": fila `MLXModelRow` con descarga verificada/estado/eliminar (`AppServices.mlxDownloaded/downloadMLX/deleteMLXModel`); `HardwareRecommender` lo sugiere con RAM ≥ 8 GB sin Apple Intelligence ni Ollama. **Shipping**: SwiftPM no compila shaders Metal → `scripts/build-mlx-metallib.sh` cachea `mlx-swift_Cmlx.bundle` (xcodebuild one-time, keyed por versión de mlx-swift) y `make-app.sh` lo copia a `Contents/Resources`. **Verificación E2E**: `portavoz-app --mlx-smoke [real]` — sintética ES en 3 s; con `real` resume la reunión más reciente de la biblioteca (solo lectura). Verificado con una reunión real de 40 min / 686 segmentos: 44 s, decisiones y action items coherentes. No hay test bajo `swift test` porque el runner CLI no puede tener metallib. **Memoria (crítico)**: sin `MLX.GPU.set(cacheLimit:)` el cache de buffers de MLX crece sin límite en prompts largos — observado 31 GB de RSS en esa misma reunión hasta que macOS suspendió el proceso. `MLXModelCache` fija 20 MB (el valor de LLMEval) y `maxTokens: 2048` como tope de generación; con eso el pico real es ~4.5 GB (pesos 2.3 GB + KV + runtime).

## Caché por fingerprint + pivote de traducción (D25) — `SummaryFingerprint` + `translate`

- **`SummaryFingerprint.compute(request:providerID:)`**: SHA-256 del MATERIAL y el método — transcript formateado (con nombres de speakers: renombrar S1→José invalida, porque cambia las atribuciones), bloque de notas D28, glosario, recipe, providerID y `promptVersion` (constante a bumpear cuando los prompts cambien de fondo). **Excluye el idioma de salida a propósito** — eso es lo que habilita el pivote. Cada provider estampa el fingerprint en el draft que produce.
- **Regenerar (detalle)**: mismo fingerprint + mismo idioma ya guardado → aviso "ya está al día" sin llamada al modelo (greedy reproduciría lo mismo); mismo fingerprint en OTRO idioma → `translate(pivot)`; si no → resumen completo.
- **`translate(_:to:glossary:)`**: parsea el markdown del pivote de vuelta a estructura (`StructuredSummary.parse` — invertible porque TODO snapshot sale de nuestro renderer; round-trip testeado) y traduce **por piezas: una llamada para el overview, una por sección, una para los action items**. Piecewise porque entregado entero — incluso con schema guiado — el 3B inventaba secciones (2 iteraciones falladas del test gated: markdown opaco → truncó al primer párrafo; schema espejado de una llamada → 3 secciones de 1). La estructura sobrevive por construcción; cualquier mismatch de bullets/items lanza y el caller cae a re-resumen completo. Owners de items viajan posicionalmente; el resultado conserva el fingerprint del pivote. **Medido: 2.4 s constante vs 10.9 s el re-resumen del sintético largo** (el ahorro escala con la reunión).

## RAG local (D22) — `SentenceEmbedder` + `RAGAnswerer` + storage

- **Embeddings**: `NLContextualEmbedding(script: .latin)` — espacio compartido es/en (cross-lingüe real). Mean-pool + L2-normalize. `prepare()` pide los assets al OS.
- **Índice**: BLOB en la columna `embedding` de `segment` + coseno brute-force (sqlite-vec diferido a propósito). Micro-segmentos (< 20 chars) EXCLUIDOS del índice (ahogaban los hits cross-lingües).
- **Retrieval híbrido**: FTS5 con OR de palabras de contenido ≥ 4 chars (el AND de la pregunta literal nunca matchea) + semántico; fusión RRF (k=60). Multi-query: FM genera paráfrasis bilingües de la pregunta (`expandQuery`).
- **Respuesta**: FM on-device con citas `[n]` que mapean a segmentos (meetingID + timestamp). Verificado E2E: agente MCP respondió "what did we agree about the transcription budget?" con fuentes correctas.

## Notas de coautoría (D28) — el tejido notas→resumen (implementado)

- `SummaryRequest.contextItems`: las notas del usuario viajan al pase FINAL como intención. `PromptFactory.notesBlock` las formatea timestampeadas (`[mm:ss] nota`), cronológicas, con presupuesto duro (120 chars/nota, 800 el bloque — testeado).
- **Presupuesto del 3B respetado**: el bloque comparte la ventana con el material condensado, así que el target del reduce se ENCOGE exactamente lo que ocupa el bloque (`condense(reduceBudget:)`).
- Instrucciones (`notesBehavior`): cada nota es un tema que el resumen DEBE cubrir, expandido con hechos, jamás contradicho; los bullets nacidos de una nota se prefijan **"▸ "** — un token barato en vez de inflar el schema del guided generation; el renderer puede pintar la coautoría estilo Granola (negro/gris) sin cambiar tipos. La orden de idioma sigue cerrando el prompt (D18).
- Flujo completo cableado: **panel de notas en `RecordingView`** (TextField + lista timestampeada con quitar, columna derecha, siempre visible durante la grabación) → `RecordingController.addContextNote()` (ancla al momento actual) → resumen rodante y final las ven → se persisten al stop (tabla `contextItem`, migración v3) → regenerar en el detalle las recarga del store. **Render de coautoría** en `MarkdownText`: los bullets con prefijo "▸ " se pintan con marca de acento (estilo Granola — lo que nació de tu nota se distingue del resumen puro de la IA). M10 completo salvo verificación de campo (5 notas reales → resumen que las expande).

## Companion en vivo (D26) — `LiveCompanion` + `QuestionHeuristic` + `CompanionCard`

Pipeline de 3 etapas sobre filas cerradas del coalescer (una fila cierra cuando nace la siguiente — nunca parciales, nunca re-proceso):
1. **Gate puro** (testeado, es/en): `looksLikeQuestion` (`?`/`¿`, interrogativos iniciales, mínimo 12 chars) **O `mentions(ownerName)`** — el detector "te preguntaron": match de palabra completa, case/diacritic-insensitive, del primer nombre o nombre completo ("John" NO dispara dentro de "Johnny"). El nombre sale de Ajustes ("Tu nombre") con default `NSFullUserName()`. El caso común (nadie preguntó) cuesta cero.
2. **Clasificador FM** (`DetectedQuestion` @Generable: isQuestion/question/kind) al scheduler con `.live` + key `companion-detect` (latest-wins: los ticks jamás se apilan). `logistics` → sin tarjeta (el modo de fallo clásico de esta clase de features), **salvo que la caption te nombre**: entonces la tarjeta es un PING ("te preguntaron", pregunta sin respuesta inventada, tinte naranja). Dos lecciones del 3B cazadas por el test gated: (a) `directed` es SIEMPRE el gate determinístico de nombre, jamás la opinión del modelo (pedírselo como campo → limpió "Johnny," de la pregunta y reportó false); (b) el filtro de logística necesita ejemplos few-shot literales ("¿nos acompañas mañana…?" es logistics NO context) — con la regla abstracta sola, se fugaba.
3. **Respuesta**: `knowledge` → BYOK si el usuario lo configuró Y activó el opt-in (`BYOKSettings.companionClient()`, mismas instrucciones que on-device, 400 tokens máx, `source` = host del proveedor; si la llamada cloud falla, cae a FM on-device y lo dice en `source`); sin BYOK → FM directo (1–3 frases, mismo idioma, greedy, 220 tokens máx, `.interactive`). `context` → `RAGAnswerer` con las últimas ~13 filas vivas como pasajes ("¿qué dijimos del budget?" responde de lo RECIÉN dicho) — el contexto de la reunión JAMÁS va al BYOK, solo el texto de la pregunta `knowledge` (D8).

App: opt-in por grabación (toggle "Companion" junto al de traducción, persiste en `companionEnabled`); tarjetas ilimitadas, newest-first y con scroll (pregunta + respuesta + procedencia — host del proveedor u "on-device" — + copiar/descartar). Al cerrar se persisten en `companionCard`; el detalle las revisa y salta al momento preguntado. Refine las re-deriva: un pase incompleto conserva el snapshot anterior y un pase completo lo reemplaza, incluso por vacío para retirar preguntas stale. La limpieza de respuestas solo elimina citas verbales `passage N` al final, nunca texto legítimo intermedio. Nunca responde por ti (D26). Settings: sección "Modelo externo (BYOK)" con endpoint/modelo/key + el toggle del Companion deshabilitado hasta que todo esté configurado; eliminar la key apaga el toggle. Presupuesto de latencia: acotado por D29 (detección `.live` reemplazable + respuesta `.interactive` con espera ≤ llamada en vuelo).

## Naming

Ver spec 03 (SpeakerNamer + NamingExcerpt + filtro never-trust-verify).

## Límites conocidos

1. **Sin Apple Intelligence no hay resumen local** — el hueco que D25/M12 cierra (Ollama primera clase → MLX embebido).
2. Recipes: solo `general` implementada; librería de recipes es M13b.
3. RAG brute-force: O(n) sobre embeddings — sin medir a 1,000+ reuniones (target < 50 ms probablemente exige sqlite-vec entonces).
4. ~~Sin política de prioridad del FM~~ — resuelto con `IntelligenceScheduler` (D29).

## Planeado (no implementado)

Resúmenes BYOK desde la app (la plomería Keychain ya existe; falta el selector de provider en el detalle — M12).
