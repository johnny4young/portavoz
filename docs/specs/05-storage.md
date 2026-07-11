# Spec 05 — Persistencia (StorageKit)

Estado: implementado y en producción (la DB del usuario sobrevivió un incidente real gracias a los tombstones). Decisiones: D4 (contrato congelado), D19 (GRDB+FTS5).

## Base de datos

GRDB 7 (`upToNextMajor(from: 7.11.1)`), SQLite WAL, en `~/Library/Application Support/Portavoz/portavoz.sqlite` (`MeetingStore.defaultDatabaseURL`; CLI acepta `--db`).

### Schema (migraciones `v1`–`v4` en `Sources/StorageKit/Schema.swift`)

Tablas singulares camelCase, 1:1 con records Codable:

| Tabla | Columnas clave |
|---|---|
| `meeting` | id (UUID TEXT PK), title, startedAt, endedAt, language, audioDirectory (RELATIVO), retention, visibility (reservada), createdAt/updatedAt/deletedAt |
| `speaker` | id, meetingID (FK CASCADE), label (S1/Me…), displayName, isMe, tombstone |
| `segment` | id, meetingID, speakerID?, channel, text, language?, startTime/endTime, confidence?, isFinal, **embedding BLOB** (v2), tombstone |
| `summary` | id, meetingID, recipeID, language, markdown, **version** (UNIQUE meetingID+recipeID+version — snapshots inmutables), **fingerprint** (v4, D25 — identidad del material sin idioma; NULL en snapshots viejos = jamás matchean) |
| `actionItem` | id, summaryID (FK CASCADE), meetingID, text, ownerSpeakerID?, isDone (la excepción MUTABLE), tombstone |
| `contextItem` (v3) | id, meetingID (FK CASCADE), kind (note/link/codeSnippet/file), content, timestamp (segundos desde el inicio), tombstone — las notas del usuario (D28) |
| `segmentSearch` | FTS5 external-content sobre segment.text, sincronizada por triggers ai/ad/au |

### Contrato D4 (ejecutado, no aspiracional)

- PKs = UUID string. `updatedAt` en cada write, `createdAt` preservado en updates (los `save()` hacen fetch-first).
- **Tombstones, jamás hard delete** (`deletedAt`; sync futuro los necesita). Esto permitió restaurar una reunión que un refine defectuoso había reemplazado.
- **Paths relativos only**: `save(meeting)` RECHAZA absolutos o `..` (`StorageError.absolutePathRejected`).
- Embedding preservado cuando el texto no cambió (save de segments compara text).

## MeetingStore — API

`save(meeting/speakers/segments/contextItems)`, `contextItems(for:)`, `deleteContextItem(_:)` (tombstone), `meetings(includeDeleted:)`, `detail(id)` (meeting+speakers+segments vivos), `delete(id)` (tombstone), `saveSummary(draft)` (versión autoincremental por meeting+recipe; jamás toca snapshots previos; persiste el fingerprint D25), `summary(id)` (último snapshot + versión), `latestSummary(id:fingerprint:language:)` (D25 — con `language` es el cache-hit exacto, sin él devuelve el pivote de traducción en cualquier idioma), `search(text, requireAll:)` (FTS5 con snippets; `ftsQuery` entrecomilla tokens — input hostil sanitizado), `searchSemantic(vector, limit:)`, `segmentsNeedingEmbeddings`/`storeEmbeddings`, `openActionItems`/`setActionItem(done:)`, `replaceCast(for:speakers:segments:)` (tombstonea el cast vivo e inserta el nuevo, atómico — el refine D7), `enforceAudioRetention(audioRoot:)` (borra SOLO audio expirado según la policy del meeting, jamás transcript; guard anti path-escape).

## Carpeta de grabaciones — `RecordingsLocation`

- Raíz elegible por el usuario; persiste como path absoluto plano en `recordings-root.txt` JUNTO A LA DB (archivo, no UserDefaults → el CLI honra la misma carpeta). Sin security-scoped bookmark: la app tiene hardened runtime pero NO sandbox; TCC pide una vez para carpetas protegidas (usage strings en el Info.plist, discos externos incluidos).
- `currentRoot()` cae al default si el marker apunta a una carpeta desaparecida (disco desconectado). `resolve(relative)` prueba raíz actual → default (una migración interrumpida sigue leyéndose completa).
- `migrateAudio(from:to:progress:)` resumable: un directorio-reunión (UUID inmutable) a la vez; cross-volume copia a `.partial-<n>` y publica con rename atómico; destino existente = ya migrado (salta y limpia fuente). 7 tests.

## Layout de audio — `MeetingAudioLayout`

`channelFile(named:in:)` localiza el audio por canal dentro de `Audio/<uuid>/`: prefiere `.caf` (captura actual, crash-safe) y cae a `.wav` (reuniones pre-jul-2026). Todos los lectores (refine CLI y app) pasan por aquí.

## Secretos — `PortavozCore.SecretStore`

Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Services: token GitHub, token Linear, llave del voiceprint. Nunca en SQLite/UserDefaults.

## Límites conocidos

1. Sin SQLCipher (opcional planeado, PRODUCT/seguridad).
2. Sin columna `provenance` (qué engine produjo cada resumen/segmento) — planeada en D25, aditiva.
3. `visibility` reservada sin uso (sharing D12).
4. FTS a 1,000 reuniones sin medir (corpus sintético pendiente, spec 08).

## Papelera (jul 2026)

Los deletes SIEMPRE fueron tombstones (D4); la papelera les da puerta de regreso. `deletedMeetings()` (tombstoned, más reciente primero), `restore(_:)` (limpia el tombstone del meeting — los hijos nunca se tombstonean, las queries filtran a través del meeting, así que TODO vuelve), `purge(_:)` (hard-DELETE de todas las filas; se REHÚSA en reuniones vivas — la papelera es la única puerta; el FTS se limpia solo vía los triggers `synchronize` de GRDB; borrar el audio en disco es del caller). App: sección "Recently deleted" al fondo del sidebar (colapsada; invisible vacía; items cargados por el reload del PADRE — un lifecycle modifier sobre una view-que-produce-Section dentro de una List no dispara confiablemente), restore de un click, "Delete permanently" por context menu (`AppServices.purgeMeeting` borra filas + carpeta de audio), y auto-purge >30 días al launch (`purgeExpiredTrash`). Verificado E2E: borrar → aparece → restore → vuelve completa. 2 tests (round-trip con hijos; purge rehusa vivas y limpia FTS).
