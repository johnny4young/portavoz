import Foundation

/// Closed English/Spanish vocabularies for the stated-priority baseline. Every
/// entry is a folded lemma or word, matched only after `NLTagger` has assigned
/// the token's lexical class, so a qualifier and a verb never share a reading.
enum StatedPriorityLexicon {
    static let anchorNouns: Set<String> = [
        "priority", "focus", "precedence", "prioridad", "foco", "enfoque", "precedencia",
        "prioritario"
    ]
    static let firstWords: Set<String> = ["first", "primero", "primera"]
    static let firstVerbs: Set<String> = ["come", "go", "ir", "venir"]
    static let importantWords: Set<String> = ["important", "importante"]
    static let mostWords: Set<String> = ["most", "mas"]
    static let leastWords: Set<String> = ["least", "menos"]
    static let prioritizingVerbs: Set<String> = ["prioritize", "prioritise", "priorizar"]
    static let deprioritizingVerbs: Set<String> = ["deprioritize", "deprioritise", "despriorizar"]
    /// Verbs that act on the priority itself ("lower the priority of X").
    static let demotingVerbs: Set<String> = [
        "lower", "drop", "reduce", "decrease", "bajar", "reducir", "quitar", "restar", "rebajar"
    ]

    static let linkingVerbs: Set<String> = ["be", "ser"]
    /// Verbs that may join a subject to a following anchor noun.
    static let subjectVerbs: Set<String> = [
        "be", "ser", "take", "have", "get", "become", "remain", "stay", "tener", "llevar",
        "convertir", "seguir", "continuar"
    ]
    static let holdPhrases: [[String]] = [["on", "hold"], ["en", "pausa"], ["en", "espera"]]
    static let holdPlacingVerbs: Set<String> = [
        "put", "leave", "keep", "place", "park", "dejar", "poner", "mantener"
    ]
    static let holdStateVerbs: Set<String> = [
        "be", "stay", "remain", "go", "ser", "estar", "quedar", "seguir"
    ]

    static let negations: Set<String> = [
        "not", "no", "never", "nunca", "jamas", "ni", "ningun", "ninguno", "ninguna"
    ]
    /// "stops being": a negation spelled as a verb of ceasing.
    static let ceasingVerbs: Set<String> = ["stop", "cease"]
    static let demotingQualifiers: Set<String> = [
        "low", "lower", "lowest", "least", "last", "secondary", "minor",
        "bajo", "baja", "menor", "minimo", "ultimo", "secundario"
    ]
    static let promotingQualifiers: Set<String> = [
        "high", "higher", "highest", "top", "main", "alto", "alta", "maximo", "principal"
    ]
    static let intensifiers: Set<String> = [
        "very", "really", "pretty", "quite", "rather", "much", "muy", "bastante", "mas", "realmente"
    ]

    static let auxiliaries: Set<String> = [
        "do", "be", "will", "can", "would", "could", "should", "have", "might", "must"
    ]
    static let discourseMarkers: Set<String> = [
        "so", "okay", "ok", "well", "and", "but", "then", "yeah", "yes", "right", "alright",
        "now", "bueno", "pues", "entonces", "y", "pero", "vale", "bien", "mira", "oye", "ahora",
        "si", "claro", "please", "porfa"
    ]
    static let pronouns: Set<String> = [
        "it", "that", "this", "these", "those", "eso", "esto", "esa", "ese", "ello", "aquello",
        "lo", "la", "le"
    ]
    static let interrogatives: Set<String> = [
        "what", "which", "who", "whats", "que", "cual", "cuales", "quien"
    ]
    static let topicQuestionLeads: [[String]] = [
        ["what", "about"], ["how", "about"], ["and"], ["que", "tal"], ["que", "pasa", "con"],
        ["que", "hay", "de"], ["y"]
    ]
    static let contrastWords: Set<String> = ["but", "pero", "sino"]
    /// A target ends where a comparison with another target begins.
    static let comparisonWords: Set<String> = [
        "over", "before", "instead", "than", "rather", "sobre", "antes"
    ]
    static let correctionMarkers: [[String]] = [
        ["i", "mean"], ["or", "rather"], ["mejor", "dicho"], ["sorry"], ["perdon"], ["digo"],
        ["actually"], ["en", "realidad"], ["wait"]
    ]
    static let retractions: [[String]] = [
        ["scratch", "that"], ["forget", "that"], ["forget", "it"], ["never", "mind"],
        ["olvidalo"], ["olvida", "eso"], ["mejor", "no"], ["cancela", "eso"]
    ]

    static let temporalWords: Set<String> = [
        "today", "tonight", "tomorrow", "now", "currently", "week", "sprint", "month", "quarter",
        "year", "morning", "afternoon", "hoy", "manana", "ahora", "actualmente", "semana", "mes",
        "trimestre", "ano", "tarde"
    ]
    static let temporalModifiers: Set<String> = [
        "this", "the", "for", "right", "rest", "of", "that", "through", "until", "esta", "este",
        "por", "el", "la", "de", "del", "resto", "lo", "que", "queda", "para", "durante", "todo",
        "toda", "en"
    ]

    static let reportingWords: Set<String> = [
        "say", "tell", "claim", "mention", "write", "according", "decir", "comentar", "opinar",
        "afirmar", "escribir", "segun"
    ]
    static let hypotheticalWords: Set<String> = [
        "if", "unless", "suppose", "supposing", "imagine", "would", "'d", "could", "might",
        "maybe", "perhaps", "probably", "possibly", "should", "quizas", "quiza", "ojala",
        "supongamos", "imagina", "imaginemos", "seria", "serian", "podria", "podrian", "deberia",
        "deberian", "tendria"
    ]
    static let hypotheticalPhrases: [[String]] = [["tal", "vez"], ["a", "lo", "mejor"], ["en", "caso"]]
    static let futureWords: Set<String> = [
        "will", "'ll", "shall", "sera", "seran", "next", "proximo", "proxima"
    ]
    static let futurePhrases: [[String]] = [["going", "to"], ["va", "a", "ser"], ["van", "a", "ser"]]
    static let pastWords: Set<String> = [
        "was", "were", "been", "used", "came", "went", "took", "had", "fue", "fueron", "era",
        "eran", "sido", "tuvo", "tenia", "iba", "vino"
    ]
    static let uncertaintyWords: Set<String> = [
        "know", "sure", "certain", "saber", "seguro", "segura", "cierto"
    ]
    static let reversalPhrases: [[String]] = [
        ["or", "not"], ["o", "no"], ["or", "maybe"], ["o", "tal", "vez"]
    ]
    /// Text addressed to an assistant is data, never a meeting declaration.
    static let assistantWords: Set<String> = [
        "assistant", "bot", "ai", "chatbot", "portavoz", "apuntador", "asistente", "siri",
        "ignore", "ignorar", "instructions", "instrucciones", "prompt"
    ]
    static let assistantImperatives: Set<String> = [
        "ignore", "mark", "flag", "label", "tag", "record", "note", "write", "add", "save", "set",
        "make", "treat", "log", "ignorar", "marcar", "etiquetar", "anotar", "apuntar",
        "registrar", "guardar", "poner", "agregar", "anadir", "tratar"
    ]
}
