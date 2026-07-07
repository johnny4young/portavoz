# Spec 04 — Inteligencia (IntelligenceKit)

Estado: implementado y verificado (resumen ES de reunión EN con glosario intacto en 3.8 s; RAG respondiendo con citas vía MCP). Decisiones: D8 (local por defecto, BYOK explícito), D18 (FM map-reduce), D22 (RAG), D26 (Copiloto — planeado).

## Scheduler del modelo — `IntelligenceScheduler` (D29)

Actor single-flight que serializa TODA llamada al FM del proceso con prioridades `interactive > live > background`, FIFO por clase, latest-wins por `key` (para ticks descartables del Copiloto) y cancelación del caller. Granularidad = una llamada: las cadenas map-reduce sueltan el slot entre pasos → la espera de un job interactivo queda acotada por la llamada en vuelo (~1–4 s). Sin dependencia de FM (7 tests puros, corren en cualquier plataforma). Los métodos públicos del provider aceptan `priority:` (default `.interactive`); el resumen rodante de la app pasa `.background`. Swift 6: `Response<T>` no es Sendable → los closures devuelven payloads construidos dentro del slot.

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

## BYOK — `OpenAICompatibleSummaryProvider` (D8)

Cualquier endpoint `/chat/completions` (cubre Ollama/LM Studio/Groq/OpenRouter). Opt-in explícito y etiquetado; key por `PORTAVOZ_BYOK_API_KEY` en CLI. Produce el mismo `StructuredSummary` neutro.

## RAG local (D22) — `SentenceEmbedder` + `RAGAnswerer` + storage

- **Embeddings**: `NLContextualEmbedding(script: .latin)` — espacio compartido es/en (cross-lingüe real). Mean-pool + L2-normalize. `prepare()` pide los assets al OS.
- **Índice**: BLOB en la columna `embedding` de `segment` + coseno brute-force (sqlite-vec diferido a propósito). Micro-segmentos (< 20 chars) EXCLUIDOS del índice (ahogaban los hits cross-lingües).
- **Retrieval híbrido**: FTS5 con OR de palabras de contenido ≥ 4 chars (el AND de la pregunta literal nunca matchea) + semántico; fusión RRF (k=60). Multi-query: FM genera paráfrasis bilingües de la pregunta (`expandQuery`).
- **Respuesta**: FM on-device con citas `[n]` que mapean a segmentos (meetingID + timestamp). Verificado E2E: agente MCP respondió "what did we agree about the transcription budget?" con fuentes correctas.

## Copiloto en vivo (D26) — `LiveCopilot` + `QuestionHeuristic` + `CopilotCard`

Pipeline de 3 etapas sobre filas cerradas del coalescer (una fila cierra cuando nace la siguiente — nunca parciales, nunca re-proceso):
1. **`QuestionHeuristic.looksLikeQuestion`** (puro, testeado, es/en): gate gratis — `?`/`¿`, interrogativos iniciales, mínimo 12 chars. El caso común (nadie preguntó) cuesta cero.
2. **Clasificador FM** (`DetectedQuestion` @Generable: isQuestion/question/kind) al scheduler con `.live` + key `copilot-detect` (latest-wins: los ticks jamás se apilan). `logistics` → sin tarjeta (el modo de fallo clásico de esta clase de features).
3. **Respuesta**: `knowledge` → FM directo (1–3 frases, mismo idioma, greedy, 220 tokens máx, `.interactive`); `context` → `RAGAnswerer` con las últimas ~13 filas vivas como pasajes ("¿qué dijimos del budget?" responde de lo RECIÉN dicho).

App: opt-in por grabación (toggle "Copiloto" junto al de traducción, persiste en `copilotEnabled`); tarjetas en el panel derecho (pregunta + respuesta + procedencia "on-device" + copiar/descartar, máx 3 visibles). Nunca responde por ti (D26). BYOK para `knowledge`: **planeado**, hoy solo on-device. Presupuesto de latencia: acotado por D29 (detección `.live` reemplazable + respuesta `.interactive` con espera ≤ llamada en vuelo).

## Naming

Ver spec 03 (SpeakerNamer + NamingExcerpt + filtro never-trust-verify).

## Límites conocidos

1. **Sin Apple Intelligence no hay resumen local** — el hueco que D25/M12 cierra (Ollama primera clase → MLX embebido).
2. Recipes: solo `general` implementada; librería de recipes es M13b.
3. RAG brute-force: O(n) sobre embeddings — sin medir a 1,000+ reuniones (target < 50 ms probablemente exige sqlite-vec entonces).
4. ~~Sin política de prioridad del FM~~ — resuelto con `IntelligenceScheduler` (D29).

## Planeado (no implementado)

Copiloto: BYOK para `knowledge` con disclosure de proveedor; detector "te preguntaron" (mención de tu nombre) unificado a la etapa 2. Notas de coautoría (D28/M10): `contextItems` en `SummaryRequest` como intención del usuario. Caché de resumen por fingerprint + pivote EN→re-traducción (parámetros de Meetily, D25).
