import Foundation

/// Deterministic, offline query expansion for instant exact-search surfaces.
///
/// Ask can use semantic retrieval and Foundation Models when available, but
/// the sidebar must remain fast on every supported Mac. This compact lexicon
/// covers calendar language and common meeting concepts in both directions;
/// unknown terms remain untouched so product names and technical vocabulary
/// keep their exact spelling.
public struct BilingualSearchQueryExpander: Sendable {
    public init() {}

    public func expand(_ source: String) -> [String] {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }

        let tokens = source.split(whereSeparator: \.isWhitespace)
        let normalizedTokens = tokens.map(Self.key(for:))
        var changed = false
        var translatedTokens: [String] = []
        var index = 0

        while index < tokens.count {
            let remainingCount = tokens.count - index
            let maximumLength = min(Self.maximumPhraseLength, remainingCount)
            var match: (length: Int, replacement: String)?

            for length in stride(from: maximumLength, through: 1, by: -1) {
                let key = normalizedTokens[index..<(index + length)]
                    .joined(separator: " ")
                guard let replacement = Self.translations[key],
                      Self.shouldTranslate(
                        key,
                        original: tokens[index],
                        tokenCount: tokens.count)
                else { continue }
                match = (length, replacement)
                break
            }

            if let match {
                changed = true
                translatedTokens.append(contentsOf:
                    match.replacement.split(separator: " ").map(String.init))
                index += match.length
            } else {
                translatedTokens.append(String(tokens[index]))
                index += 1
            }
        }

        let translated = translatedTokens.joined(separator: " ")

        guard changed, Self.key(for: translated) != Self.key(for: source) else {
            return [source]
        }
        return [source, translated]
    }

    private static func shouldTranslate(
        _ key: String,
        original: Substring,
        tokenCount: Int
    ) -> Bool {
        // Lowercase "may" is usually a modal verb, not the month. Preserve
        // it unless the query is just the month or the user capitalized it.
        guard key == "may" else { return true }
        return tokenCount == 1 || original.first?.isUppercase == true
    }

    private static func key<S: StringProtocol>(for value: S) -> String {
        value.trimmingCharacters(in: .punctuationCharacters)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
    }

    // This is search data, not localized UI copy. Keep each pair explicit so
    // ambiguous terms can be admitted in only the safe direction.
    private static let translations: [String: String] = {
        var values: [String: String] = [:]
        func pair(_ english: String, _ spanish: String) {
            values[key(for: english)] = spanish
            values[key(for: spanish)] = english
        }

        pair("january", "enero")
        pair("february", "febrero")
        pair("march", "marzo")
        pair("april", "abril")
        values["may"] = "mayo"
        values["mayo"] = "may"
        pair("june", "junio")
        pair("july", "julio")
        pair("august", "agosto")
        pair("september", "septiembre")
        pair("october", "octubre")
        pair("november", "noviembre")
        pair("december", "diciembre")

        pair("monday", "lunes")
        pair("tuesday", "martes")
        pair("wednesday", "miércoles")
        pair("thursday", "jueves")
        pair("friday", "viernes")
        pair("saturday", "sábado")
        pair("sunday", "domingo")

        pair("meeting", "reunión")
        pair("meetings", "reuniones")
        pair("summary", "resumen")
        pair("decision", "decisión")
        pair("decisions", "decisiones")
        pair("action", "acción")
        pair("actions", "acciones")
        pair("task", "tarea")
        pair("tasks", "tareas")
        pair("budget", "presupuesto")
        pair("deadline", "fecha límite")
        pair("deadlines", "fechas límite")
        pair("issue", "problema")
        pair("issues", "problemas")
        pair("risk", "riesgo")
        pair("risks", "riesgos")
        pair("blocker", "bloqueo")
        pair("blockers", "bloqueos")
        pair("deployment", "despliegue")
        pair("release", "lanzamiento")
        pair("launch", "lanzamiento")
        pair("roadmap", "hoja de ruta")
        pair("project", "proyecto")
        pair("projects", "proyectos")
        pair("customer", "cliente")
        pair("customers", "clientes")
        pair("team", "equipo")
        pair("teams", "equipos")
        pair("week", "semana")
        pair("month", "mes")
        pair("quarter", "trimestre")
        pair("year", "año")
        pair("today", "hoy")
        pair("tomorrow", "mañana")
        pair("yesterday", "ayer")
        pair("test", "prueba")
        pair("tests", "pruebas")
        pair("migration", "migración")
        pair("schema", "esquema")
        pair("update", "actualización")
        pair("updates", "actualizaciones")
        pair("next", "próximos")
        pair("steps", "pasos")

        return values
    }()

    private static let maximumPhraseLength =
        translations.keys.lazy
            .map { $0.split(separator: " ").count }
            .max() ?? 1
}
