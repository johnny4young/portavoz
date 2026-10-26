#!/usr/bin/env python3
"""Public dictation-search corpus and payload-free lexical/semantic/hybrid scoring."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
import unicodedata
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_FIXTURE = ROOT / "Fixtures/DictationSearch/public-synthetic-v1.json"
SCHEMA_VERSION = 1
FIXTURE_KIND = "dictation-search-fixture"
OBSERVATION_KIND = "dictation-search-observations"
SCORECARD_KIND = "dictation-search-scorecard"
GENERATION = "public-synthetic-v1"
NAMESPACE = uuid.UUID("6f1c7d2e-1b4a-4f43-9a51-0d8c2a7e5b19")
RELATIONSHIP_COUNTS = {
    "exact": 16,
    "paraphraseSpanish": 16,
    "paraphraseEnglish": 16,
    "crossLingual": 16,
    "codeSwitched": 8,
    "abstain": 8,
}
MEANING_RELATIONSHIPS = ("paraphraseSpanish", "paraphraseEnglish", "crossLingual", "codeSwitched")
RESULT_LIMIT = 12
RRF_K = 60
THRESHOLDS = tuple(round(step * 0.05, 2) for step in range(20))
GATE_RECALL_GAIN = 0.15
GATE_SEMANTIC_FALSE_POSITIVES = 0.25
GATE_QUERY_P95_MILLISECONDS = 150.0
FUNCTION_WORDS = {
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "could", "did", "do", "does", "for",
    "from", "how", "i", "if", "in", "is", "it", "of", "on", "or", "that", "the", "they", "this", "to",
    "we", "what", "when", "where", "which", "who", "with", "would", "you", "al", "como", "con", "cual",
    "cuando", "de", "del", "donde", "el", "en", "es", "este", "la", "las", "lo", "los", "o", "para",
    "por", "que", "se", "si", "son", "un", "una", "y", "yo", "mi", "me", "my", "am", "was", "were",
}


class FixtureError(ValueError):
    """Diagnostics name a contract, never a rejected value."""


def require(condition, reason):
    if not condition:
        raise FixtureError(reason)


def tokens(text):
    folded = unicodedata.normalize("NFKD", text.casefold())
    folded = "".join(ch for ch in folded if not unicodedata.combining(ch))
    words = "".join(ch if ch.isalnum() else " " for ch in folded).split()
    return {word for word in words if len(word) > 2 and word not in FUNCTION_WORDS}


# (language, app, dictation, (relationship, query), (relationship, query), hard negative)
TOPICS = [
    ("es", "Slack", "Mañana a las nueve reviso la cotización con el proveedor de pintura.",
     ("exact", "cotización del proveedor de pintura"),
     ("paraphraseSpanish", "¿Qué día miro el presupuesto del distribuidor de esmalte?"),
     "La pintura del baño quedó perfecta, no hace falta otra mano."),
    ("es", "Mail", "Envíale a Lucía el contrato firmado antes del viernes.",
     ("exact", "contrato firmado Lucía"),
     ("paraphraseSpanish", "¿A quién tenía que mandarle el acuerdo con las firmas?"),
     "El contrato de arriendo del local vence en diciembre."),
    ("es", "Notes", "Comprar leche deslactosada, pan integral y bananos para la semana.",
     ("exact", "leche deslactosada pan integral"),
     ("paraphraseSpanish", "¿Qué productos del mercado anoté para el desayuno?"),
     "Se acabó el pan en la oficina, avisar a recepción."),
    ("es", "Slack", "El despliegue a producción quedó bloqueado por la migración de la base de datos.",
     ("exact", "despliegue bloqueado migración"),
     ("paraphraseSpanish", "¿Por qué no pudimos subir la versión nueva al servidor?"),
     "La migración de aves al sur empieza en octubre según el documental."),
    ("es", "Messages", "Recoger a Sofía en el colegio a las cuatro y media.",
     ("exact", "recoger a Sofía colegio"),
     ("paraphraseSpanish", "¿A qué hora busco a la niña en la escuela?"),
     "El colegio envió la circular de la excursión de noviembre."),
    ("es", "Notion", "La reunión de planeación se pasa al jueves por la tarde.",
     ("exact", "reunión de planeación"),
     ("paraphraseSpanish", "¿Cuándo quedó movida la sesión para organizar el trimestre?"),
     "La planeación del viaje quedó lista desde el jueves."),
    ("es", "Mail", "Pedir reembolso del pasaje de avión cancelado por la aerolínea.",
     ("exact", "reembolso pasaje cancelado"),
     ("paraphraseSpanish", "¿Qué dije de recuperar el dinero del vuelo que suspendieron?"),
     "La aerolínea cambió la puerta de embarque a la doce."),
    ("es", "Notes", "Llamar al plomero porque la llave del lavaplatos sigue goteando.",
     ("exact", "plomero lavaplatos goteando"),
     ("paraphraseSpanish", "¿Qué arreglo de la cocina tengo pendiente con el fontanero?"),
     "La llave del carro quedó en el cajón de la entrada."),
    ("es", "Slack", "Hay que subir el precio del plan anual un ocho por ciento en enero.",
     ("paraphraseSpanish", "¿Cuánto vamos a aumentar la suscripción de doce meses?"),
     ("crossLingual", "How much will the yearly subscription go up?"),
     "El plan de vacaciones de enero todavía no está claro."),
    ("es", "Notes", "Idea para el blog: escribir sobre cómo organizamos el inventario con códigos QR.",
     ("paraphraseSpanish", "¿Qué tema se me ocurrió para publicar acerca del control de existencias?"),
     ("crossLingual", "What post did I want to write about tracking stock with scannable labels?"),
     "Los códigos de descuento del blog expiran mañana."),
    ("es", "Mail", "Agradecerle a Martín por cubrir mi turno del sábado.",
     ("paraphraseSpanish", "¿A quién debía decirle gracias por reemplazarme en la jornada?"),
     ("crossLingual", "Who did I need to thank for taking my shift?"),
     "Martín pidió cambiar su turno de la noche."),
    ("es", "Messages", "El médico dijo que tome el antibiótico cada ocho horas por siete días.",
     ("paraphraseSpanish", "¿Con qué frecuencia me toca la medicina que recetaron?"),
     ("crossLingual", "How often do I take the medicine the doctor prescribed?"),
     "El médico de la empresa atiende los martes."),
    ("es", "Notion", "Revisar los permisos de acceso de los practicantes al repositorio.",
     ("paraphraseSpanish", "¿Qué tenía que verificar sobre lo que pueden ver los estudiantes en el código?"),
     ("crossLingual", "What did I need to check about the interns' access to the codebase?"),
     "Los practicantes llegan con la nueva cohorte de marzo."),
    ("es", "Slack", "El cliente de Monterrey quiere la demo en inglés y con datos reales.",
     ("paraphraseSpanish", "¿Cómo pidió la presentación la empresa del norte?"),
     ("crossLingual", "How did the client up north want the product walkthrough?"),
     "Monterrey tiene pronóstico de lluvia toda la semana."),
    ("es", "Mail", "Renovar el seguro del carro antes de que venza la póliza.",
     ("paraphraseSpanish", "¿Qué trámite del vehículo tengo que hacer con la aseguradora?"),
     ("crossLingual", "What do I have to do about the car insurance before it expires?"),
     "El carro nuevo de Andrés es eléctrico."),
    ("es", "Notes", "Practicar la presentación tres veces en voz alta antes de la conferencia.",
     ("paraphraseSpanish", "¿Cómo me iba a preparar para la charla del congreso?"),
     ("crossLingual", "How was I going to rehearse for the talk at the convention?"),
     "La conferencia de prensa empieza a las diez."),
    ("en", "Slack", "Ask Priya to review the onboarding checklist before Thursday's launch.",
     ("exact", "Priya onboarding checklist"),
     ("paraphraseEnglish", "Who should look over the new hire steps?"),
     "The launch party moved to the rooftop."),
    ("en", "Mail", "Send the invoice for the March consulting hours to accounting.",
     ("exact", "invoice consulting hours"),
     ("paraphraseEnglish", "Which bill do I owe the finance team?"),
     "Accounting hours change during the holidays."),
    ("en", "Notes", "Buy batteries, a lightbulb and duct tape for the garage.",
     ("exact", "batteries lightbulb duct tape"),
     ("paraphraseEnglish", "What hardware store items did I list?"),
     "The garage door opener needs a new code."),
    ("en", "Slack", "The checkout page crashes when the coupon field is empty.",
     ("exact", "checkout crashes coupon"),
     ("paraphraseEnglish", "What bug happens when people pay without a promo code?"),
     "Coupon season starts with the newsletter."),
    ("en", "Messages", "Pick up Leo from soccer practice at six.",
     ("exact", "pick up Leo soccer practice"),
     ("paraphraseEnglish", "When do I collect my son from football training?"),
     "Soccer tickets for the final sold out."),
    ("en", "Notion", "Move the quarterly review to the first week of next month.",
     ("exact", "quarterly review"),
     ("paraphraseEnglish", "When will the periodic performance check take place?"),
     "My review of the new phone is almost done."),
    ("en", "Mail", "Cancel the gym membership before they charge the annual fee.",
     ("exact", "cancel gym membership"),
     ("paraphraseEnglish", "What subscription for working out must I stop?"),
     "The gym is closed for cleaning on Sunday."),
    ("en", "Notes", "Book a table for four at the Italian place on Friday night.",
     ("exact", "table for four Italian"),
     ("paraphraseEnglish", "Where am I taking the group to dinner?"),
     "Friday night traffic downtown is terrible."),
    ("en", "Slack", "Our churn went up to five percent after the price change.",
     ("paraphraseEnglish", "How many customers left once we raised the cost?"),
     ("crossLingual", "¿Cuántos clientes perdimos al subir la tarifa?"),
     "The price change email goes out tomorrow."),
    ("en", "Notes", "Podcast idea: interview a farmer who switched to solar irrigation.",
     ("paraphraseEnglish", "What episode concept did I come up with about agriculture?"),
     ("crossLingual", "¿Qué se me ocurrió grabar con un agricultor y paneles?"),
     "The farmer's market moved to the parking lot."),
    ("en", "Mail", "Remind Daniel that the support rota changes in November.",
     ("paraphraseEnglish", "Who must I tell about the new helpdesk schedule?"),
     ("crossLingual", "¿A quién le aviso del nuevo horario de soporte?"),
     "Daniel's vacation photos are on the shared drive."),
    ("en", "Messages", "The vet said Max needs his rabies shot renewed this year.",
     ("paraphraseEnglish", "What did the animal doctor say about the dog's vaccine?"),
     ("crossLingual", "¿Qué dijo la veterinaria sobre la vacuna del perro?"),
     "Max scored the winning goal yesterday."),
    ("en", "Notion", "Rotate the API keys for the staging environment.",
     ("paraphraseEnglish", "Which credentials do I need to replace on the test servers?"),
     ("crossLingual", "¿Qué claves tenía que cambiar en el ambiente de pruebas?"),
     "Staging the play requires three rehearsals."),
    ("en", "Slack", "The Berlin partner wants the contract in German before signing.",
     ("paraphraseEnglish", "What does the European distributor need prior to committing?"),
     ("crossLingual", "¿En qué idioma quiere el socio alemán el acuerdo?"),
     "Berlin weather is cold this week."),
    ("en", "Mail", "Renew my passport, it expires in three months.",
     ("paraphraseEnglish", "Which travel document do I have to update soon?"),
     ("crossLingual", "¿Qué documento de viaje tengo que renovar?"),
     "The passport office has a new address."),
    ("en", "Notes", "Water the tomato plants every morning while the neighbors are away.",
     ("paraphraseEnglish", "What gardening chore did I promise to do for the people next door?"),
     ("crossLingual", "¿Qué le prometí regar a los vecinos?"),
     "The neighbors are throwing a party this morning."),
    ("mixed", "Slack", "Mañana tengo el standup a las diez, después el one on one con Carla.",
     ("codeSwitched", "¿Cuándo es la reunión privada with my teammate?"), None,
     "El standup de hoy se canceló por el offsite."),
    ("mixed", "Notes", "Necesito update el deck con los numbers del Q3 antes del board meeting.",
     ("codeSwitched", "What changes le hago a la presentación para la junta directiva?"), None,
     "The board game night es el sábado."),
    ("mixed", "Messages", "Ya hice el transfer de la renta, falta el receipt del landlord.",
     ("codeSwitched", "¿Pagué el alquiler? I still need the proof from the owner."), None,
     "La renta del apartamento de playa sube en verano."),
    ("mixed", "Slack", "El bug del login en Android ya está fixed, pero falta el release.",
     ("codeSwitched", "Is the sign-in problem on the phone solved o todavía no se publica?"), None,
     "Android Studio se actualizó solo anoche."),
    ("mixed", "Mail", "Mándale el feedback a Jorge sobre su pitch, estuvo muy bueno.",
     ("codeSwitched", "What comments do I owe al compañero about his presentation?"), None,
     "Jorge mandó fotos del pitch de su hermana."),
    ("mixed", "Notes", "Pending: comprar el charger del laptop y un mouse inalámbrico.",
     ("codeSwitched", "¿Qué accessories para la computadora tenía que buy?"), None,
     "El mouse del gato está debajo del sofá."),
    ("mixed", "Notion", "La sprint review se mueve al viernes por el holiday del lunes.",
     ("codeSwitched", "Why did the demo de fin de ciclo get rescheduled?"), None,
     "El holiday party será en el rooftop."),
    ("mixed", "Messages", "Dile a mamá que llego late, el tráfico está horrible.",
     ("codeSwitched", "What message did I send a mi madre about being retrasado?"), None,
     "Mamá cocinó arroz con pollo."),
]

ABSTAIN_QUERIES = [
    "¿Qué le dije al profesor de guitarra sobre la clase?",
    "Did I reserve the hotel in Lisbon?",
    "¿Cuánto costó arreglar la lavadora?",
    "What did I say about the chess tournament?",
    "¿Confirmé la cita con el odontólogo?",
    "Where did I park the bike?",
    "¿Qué opiné sobre la película de terror?",
    "What did I tell the architect about the roof?",
]

FILLER_TEMPLATES = {
    "es": ["Recordar {}.", "Anotar que hay que {}.", "Pendiente: {}.", "No olvidar {}."],
    "en": ["Remember to {}.", "Note: {}.", "Todo: {}.", "Don't forget to {}."],
}
FILLER_ITEMS = {
    "es": ["regar las plantas del balcón", "cambiar el filtro del aire acondicionado",
           "devolver el libro a la biblioteca", "sacar copia de las llaves",
           "comprar regalo para el cumpleaños de la abuela", "revisar la presión de las llantas",
           "pagar el recibo de la luz", "reservar cancha de tenis", "lavar el tapete de la sala",
           "imprimir los boletos del concierto"],
    "en": ["water the balcony ferns", "swap the air filter", "return the library book",
           "copy the house keys", "wrap grandma's birthday present", "check the tire pressure",
           "pay the electric bill", "book a tennis court", "clean the living room rug",
           "print the concert tickets"],
}
FILLER_APPS = ["Notes", "Messages", "Slack", "Mail", "Notion"]


def stable_id(key):
    return str(uuid.uuid5(NAMESPACE, key)).upper()


def generate_public():
    base = datetime(2026, 9, 1, 8, 0, tzinfo=timezone.utc)
    dictations, queries = [], []

    def add_dictation(key, language, app, text):
        identifier = stable_id("dictation:" + key)
        created = base + timedelta(hours=2 * len(dictations))
        dictations.append({
            "id": identifier, "createdAt": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "applicationName": app, "language": language, "text": text,
        })
        return identifier

    for index, (language, app, text, first, second, negative) in enumerate(TOPICS):
        target = add_dictation(f"topic-{index}", language, app, text)
        trap = add_dictation(f"negative-{index}", language, app, negative)
        for position, entry in enumerate((first, second)):
            if entry is None:
                continue
            relationship, question = entry
            queries.append({
                "id": stable_id(f"query:{index}:{position}"), "text": question,
                "relationship": relationship, "relevant": [target], "hardNegativeIDs": [trap],
            })
    for language in ("es", "en"):
        for template_index, template in enumerate(FILLER_TEMPLATES[language]):
            for item_index, item in enumerate(FILLER_ITEMS[language]):
                app = FILLER_APPS[(template_index + item_index) % len(FILLER_APPS)]
                add_dictation(f"filler-{language}-{template_index}-{item_index}", language, app,
                              template.format(item))
    for index, question in enumerate(ABSTAIN_QUERIES):
        queries.append({
            "id": stable_id(f"abstain:{index}"), "text": question,
            "relationship": "abstain", "relevant": [], "hardNegativeIDs": [],
        })
    return {
        "schemaVersion": SCHEMA_VERSION, "kind": FIXTURE_KIND, "generation": GENERATION,
        "contentSource": "public-synthetic-only", "dictations": dictations, "queries": queries,
    }


def validate_fixture(fixture):
    require(type(fixture) is dict and set(fixture) == {
        "schemaVersion", "kind", "generation", "contentSource", "dictations", "queries"}, "fixture keys")
    require(fixture["schemaVersion"] == SCHEMA_VERSION and fixture["kind"] == FIXTURE_KIND, "fixture kind")
    dictations = {item["id"]: item for item in fixture["dictations"]}
    require(len(dictations) == len(fixture["dictations"]) == 160, "dictation identities")
    for item in fixture["dictations"]:
        require(set(item) == {"id", "createdAt", "applicationName", "language", "text"}, "dictation keys")
        require(item["language"] in {"es", "en", "mixed"} and item["text"].strip(), "dictation content")
    counts = {name: 0 for name in RELATIONSHIP_COUNTS}
    for query in fixture["queries"]:
        require(set(query) == {"id", "text", "relationship", "relevant", "hardNegativeIDs"}, "query keys")
        require(query["relationship"] in counts, "query relationship")
        counts[query["relationship"]] += 1
        require(all(item in dictations for item in query["relevant"] + query["hardNegativeIDs"]),
                "query references")
        if query["relationship"] == "abstain":
            require(not query["relevant"], "abstain relevance")
            continue
        require(len(query["relevant"]) == 1, "single relevant dictation")
        overlap = tokens(query["text"]) & tokens(dictations[query["relevant"][0]]["text"])
        if query["relationship"] == "exact":
            require(len(overlap) >= 2, "exact query shares its words")
        else:
            require(not overlap, "meaning query shares no content word with its dictation")
    require(counts == RELATIONSHIP_COUNTS, "relationship distribution")
    require(len({query["id"] for query in fixture["queries"]}) == len(fixture["queries"]), "query identities")


def canonical_bytes(document):
    return (json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def ranks(observed, relevant):
    return [index for index, identifier in enumerate(observed) if identifier in relevant]


def reciprocal_rank_fusion(lexical, semantic, limit=RESULT_LIMIT):
    scores = {}
    for ranking in (lexical, semantic):
        for rank, identifier in enumerate(ranking):
            scores[identifier] = scores.get(identifier, 0.0) + 1.0 / (RRF_K + rank)
    ordered = sorted(scores, key=lambda identifier: (-scores[identifier], identifier.upper()))
    return ordered[:limit]


def ranking(observation, adapter, threshold, lane="semantic"):
    if adapter == "lexical":
        return observation["lexical"][:RESULT_LIMIT]
    if adapter == "list":
        return (observation.get(lane) or [])[:RESULT_LIMIT]
    semantic = [hit["id"] for hit in observation[lane] if hit["similarity"] >= threshold]
    if adapter == "semantic":
        return semantic[:RESULT_LIMIT]
    return reciprocal_rank_fusion(observation["lexical"], semantic)


def score(fixture, observations, adapter, threshold=0.0, lane="semantic"):
    by_id = {item["id"]: item for item in observations["queries"]}
    totals = {}
    for query in fixture["queries"]:
        observed = ranking(by_id[query["id"]], adapter, threshold, lane)
        bucket = totals.setdefault(query["relationship"], {
            "queries": 0, "hitAt1": 0.0, "recallAt5": 0.0, "reciprocalRank": 0.0,
            "hardNegativeAboveTarget": 0.0, "anyResult": 0.0})
        bucket["queries"] += 1
        bucket["anyResult"] += 1.0 if observed else 0.0
        if query["relationship"] == "abstain":
            continue
        found = ranks(observed, set(query["relevant"]))
        first = found[0] if found else None
        bucket["hitAt1"] += 1.0 if first == 0 else 0.0
        bucket["recallAt5"] += 1.0 if first is not None and first < 5 else 0.0
        bucket["reciprocalRank"] += 1.0 / (first + 1) if first is not None else 0.0
        negatives = ranks(observed, set(query["hardNegativeIDs"]))
        if negatives and (first is None or negatives[0] < first):
            bucket["hardNegativeAboveTarget"] += 1.0
    return {
        name: {key: (value if key == "queries" else round(value / bucket["queries"], 4))
               for key, value in bucket.items()}
        for name, bucket in sorted(totals.items())
    }


def meaning_recall(metrics):
    return round(sum(metrics[name]["recallAt5"] for name in MEANING_RELATIONSHIPS) / len(MEANING_RELATIONSHIPS), 4)


def semantic_false_positives(fixture, observations, threshold, lane="semantic"):
    abstain = {query["id"] for query in fixture["queries"] if query["relationship"] == "abstain"}
    hits = sum(1 for item in observations["queries"] if item["id"] in abstain
               and any(hit["similarity"] >= threshold for hit in item[lane]))
    return round(hits / len(abstain), 4)


LANES = ("semantic", "semanticCentered")
EXPANSION_LANES = {
    "lexicalExpandedMeeting": "expansionMeetingMilliseconds",
    "lexicalExpandedDictation": "expansionDictationMilliseconds",
}


def evaluate_expansion(fixture, observations, lexical, lane, timing):
    if any(item.get(lane) is None for item in observations["queries"]):
        return {"available": False, "metrics": None, "reasons": ["on-device rewriting was unavailable"],
                "rewriteMilliseconds": None}
    metrics = score(fixture, observations, "list", lane=lane)
    reasons = []
    if metrics["exact"]["hitAt1"] < lexical["exact"]["hitAt1"]:
        reasons.append("exact precision regressed")
    if metrics["abstain"]["anyResult"] > GATE_SEMANTIC_FALSE_POSITIVES:
        reasons.append("false positives on unanswerable questions are above the gate")
    if meaning_recall(metrics) - meaning_recall(lexical) < GATE_RECALL_GAIN:
        reasons.append("meaning recall gain is below the gate")
    return {"available": True, "metrics": metrics, "meaningRecallAt5": meaning_recall(metrics),
            "reasons": reasons, "rewriteMilliseconds": observations["resources"].get(timing)}


def evaluate_lane(fixture, observations, lexical, lane):
    sweep = []
    for threshold in THRESHOLDS:
        hybrid = score(fixture, observations, "hybrid", threshold, lane)
        semantic = score(fixture, observations, "semantic", threshold, lane)
        sweep.append({
            "threshold": threshold,
            "hybridMeaningRecallAt5": meaning_recall(hybrid),
            "semanticMeaningRecallAt5": meaning_recall(semantic),
            "hybridExactHitAt1": hybrid["exact"]["hitAt1"],
            "semanticFalsePositiveRate": semantic_false_positives(fixture, observations, threshold, lane),
        })
    eligible = [row for row in sweep
                if row["semanticFalsePositiveRate"] <= GATE_SEMANTIC_FALSE_POSITIVES
                and row["hybridExactHitAt1"] >= lexical["exact"]["hitAt1"]]
    chosen = max(eligible, key=lambda row: (row["hybridMeaningRecallAt5"], row["threshold"]), default=None)
    reasons = []
    if chosen is None:
        reasons.append("no threshold keeps exact precision and semantic false positives within the gate")
    elif chosen["hybridMeaningRecallAt5"] - meaning_recall(lexical) < GATE_RECALL_GAIN:
        reasons.append("hybrid meaning recall gain is below the gate")
    threshold = chosen["threshold"] if chosen else None
    return {
        "chosenThreshold": threshold,
        "hybrid": score(fixture, observations, "hybrid", threshold, lane) if chosen else None,
        "semantic": score(fixture, observations, "semantic", threshold, lane) if chosen else None,
        "sweep": sweep,
        "reasons": reasons,
    }


def evaluate(fixture, observations):
    validate_fixture(fixture)
    require(observations.get("kind") == OBSERVATION_KIND, "observation kind")
    require({item["id"] for item in observations["queries"]} == {q["id"] for q in fixture["queries"]},
            "observation coverage")
    lexical = score(fixture, observations, "lexical")
    lanes = {lane: evaluate_lane(fixture, observations, lexical, lane) for lane in LANES}
    resources = observations["resources"]
    largest = max(resources["scale"], key=lambda row: row["dictations"])
    shared = []
    if largest["semanticP95Milliseconds"] > GATE_QUERY_P95_MILLISECONDS:
        shared.append("semantic query p95 at the largest scale is above the gate")
    expansions = {lane: evaluate_expansion(fixture, observations, lexical, lane, timing)
                  for lane, timing in EXPANSION_LANES.items()}
    passing = [lane for lane, result in lanes.items() if not result["reasons"] and not shared]
    passing += [lane for lane, result in expansions.items() if not result["reasons"]]
    return {
        "schemaVersion": SCHEMA_VERSION, "kind": SCORECARD_KIND,
        "fixtureSHA256": observations["fixtureSHA256"], "build": observations["build"],
        "commit": observations["commit"], "embeddingProfileFingerprint": observations["embeddingProfileFingerprint"],
        "lexical": lexical, "lexicalMeaningRecallAt5": meaning_recall(lexical),
        "lanes": lanes, "expansions": expansions, "resources": resources,
        "verdict": "proceed" if passing else "stop", "passingLanes": passing, "reasons": shared,
    }


def write_private(path, document):
    path = Path(path)
    require(not path.exists(), "output already exists")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(canonical_bytes(document))
        os.link(temporary, path)
    finally:
        os.unlink(temporary)


def summary(scorecard):
    def line(name, metrics):
        parts = [f"{rel} R@5 {values['recallAt5']:.2f} H@1 {values['hitAt1']:.2f}"
                 for rel, values in metrics.items() if rel != "abstain"]
        return f"{name}: " + "; ".join(parts) + f"; abstain any {metrics['abstain']['anyResult']:.2f}"

    lines = [f"verdict: {scorecard['verdict']} {scorecard['passingLanes']}", line("lexical", scorecard["lexical"])]
    for lane, result in scorecard["lanes"].items():
        lines.append(f"{lane} threshold {result['chosenThreshold']}")
        for name in ("semantic", "hybrid"):
            if result[name] is not None:
                lines.append("  " + line(name, result[name]))
        lines.extend(f"  reason: {reason}" for reason in result["reasons"])
    for lane, result in scorecard["expansions"].items():
        lines.append(f"{lane}: rewrite ms {result['rewriteMilliseconds']}")
        if result["metrics"] is not None:
            lines.append("  " + line("expanded", result["metrics"]))
        lines.extend(f"  reason: {reason}" for reason in result["reasons"])
    largest = max(scorecard["resources"]["scale"], key=lambda row: row["dictations"])
    lines.append(f"semantic p95 at {largest['dictations']}: {largest['semanticP95Milliseconds']} ms")
    lines.extend(f"reason: {reason}" for reason in scorecard["reasons"])
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("generate-public")
    commands.add_parser("verify-public")
    evaluate_parser = commands.add_parser("evaluate")
    evaluate_parser.add_argument("--fixture", default=str(PUBLIC_FIXTURE))
    evaluate_parser.add_argument("--observations", required=True)
    evaluate_parser.add_argument("--output", required=True)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "generate-public":
            document = generate_public()
            validate_fixture(document)
            PUBLIC_FIXTURE.parent.mkdir(parents=True, exist_ok=True)
            PUBLIC_FIXTURE.write_bytes(canonical_bytes(document))
        elif arguments.command == "verify-public":
            document = json.loads(PUBLIC_FIXTURE.read_bytes())
            validate_fixture(document)
            require(PUBLIC_FIXTURE.read_bytes() == canonical_bytes(generate_public()), "public fixture drift")
        else:
            fixture_bytes = Path(arguments.fixture).read_bytes()
            observations = json.loads(Path(arguments.observations).read_bytes())
            require(observations.get("fixtureSHA256") == hashlib.sha256(fixture_bytes).hexdigest(),
                    "observations belong to another fixture")
            scorecard = evaluate(json.loads(fixture_bytes), observations)
            write_private(arguments.output, scorecard)
            print(summary(scorecard))
    except (FixtureError, OSError, json.JSONDecodeError, KeyError) as error:
        message = str(error) if isinstance(error, FixtureError) else type(error).__name__
        print(f"dictation-search-quality error: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
