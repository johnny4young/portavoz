#!/usr/bin/env python3
"""Canonical query-first contract for Portavoz Meeting Memory Graph research."""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


SCHEMA_VERSION = 1
FIXTURE_KIND = "meeting-memory-graph-query-fixture"
GENERATION = "public-synthetic-v1"
CONTENT_SOURCE = "public-synthetic-only"
JOBS = (
    "decisionHistory",
    "changeSince",
    "personCommitments",
    "commitmentBlockers",
    "firstDiscussion",
    "decisionConflicts",
)
RELATIONSHIPS = (
    "englishToEnglish",
    "spanishToSpanish",
    "englishToSpanish",
    "spanishToEnglish",
    "codeSwitched",
    "abstention",
)
JOB_COUNTS = {job: len(RELATIONSHIPS) for job in JOBS}
RELATIONSHIP_COUNTS = {relationship: len(JOBS) for relationship in RELATIONSHIPS}
ABSTENTION_REASON_BY_JOB = {
    "decisionHistory": "insufficientConfirmedDecision",
    "changeSince": "missingTemporalBaseline",
    "personCommitments": "ambiguousPerson",
    "commitmentBlockers": "unsupportedCausalLink",
    "firstDiscussion": "staleEvidenceOnly",
    "decisionConflicts": "unsupportedConflict",
}
ABSTENTION_REASONS = set(ABSTENTION_REASON_BY_JOB.values())
LANGUAGES = {"en", "es", "mixed"}
FACT_KINDS = {"decision", "commitment", "topicMention", "relation"}
PREDICATES = {
    "decisionAbout",
    "committedTo",
    "discussed",
    "changes",
    "blocks",
    "associatedWith",
    "supersedes",
    "contradicts",
}
STATUSES = {
    "observed",
    "confirmed",
    "open",
    "completed",
    "superseded",
    "reversed",
}
ORIGINS = {"generated", "confirmed", "manual"}
CURRENT_RESULT_STATUSES = {
    "decision": {"confirmed"},
    "commitment": {"open", "completed"},
    "topicMention": {"confirmed"},
    "relation": {"confirmed"},
}
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")
SAFE_GENERATION = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")

JOB_DEFINITIONS = (
    {
        "id": "decisionHistory",
        "question": "What did we decide about X?",
        "questionSpanish": "¿Qué decidimos sobre X?",
        "allowedResultKinds": ["decision"],
        "ordering": "currentConfirmedFirst",
    },
    {
        "id": "changeSince",
        "question": "What changed since the last meeting?",
        "questionSpanish": "¿Qué cambió desde la última reunión?",
        "allowedResultKinds": ["relation"],
        "ordering": "afterBaselineChronological",
    },
    {
        "id": "personCommitments",
        "question": "What has this person committed to?",
        "questionSpanish": "¿A qué se comprometió esta persona?",
        "allowedResultKinds": ["commitment"],
        "ordering": "openBeforeCompleted",
    },
    {
        "id": "commitmentBlockers",
        "question": "Which open decisions block this commitment?",
        "questionSpanish": "¿Qué decisiones abiertas bloquean este compromiso?",
        "allowedResultKinds": ["relation"],
        "ordering": "directEvidenceOnly",
    },
    {
        "id": "firstDiscussion",
        "question": "Where was this term first discussed?",
        "questionSpanish": "¿Dónde se habló por primera vez de este término?",
        "allowedResultKinds": ["topicMention"],
        "ordering": "earliestCurrentEvidenceFirst",
    },
    {
        "id": "decisionConflicts",
        "question": "Show contradictory or superseding decisions with sources.",
        "questionSpanish": "Muestra decisiones contradictorias o reemplazadas con fuentes.",
        "allowedResultKinds": ["relation"],
        "ordering": "explicitRelationFirst",
    },
)


class MeetingMemoryGraphQualityError(ValueError):
    """Fail-closed fixture or canonical-public-contract error."""


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise MeetingMemoryGraphQualityError(f"duplicate key: {key}")
        result[key] = value
    return result


def load_json(path, label, maximum_bytes=4 * 1024 * 1024):
    path = Path(path).expanduser()
    try:
        if not path.is_file():
            raise MeetingMemoryGraphQualityError(f"{label} not found: {path}")
        if path.stat().st_size > maximum_bytes:
            raise MeetingMemoryGraphQualityError(f"{label} exceeds the size limit")
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except OSError as error:
        raise MeetingMemoryGraphQualityError(
            f"{label} could not be read: {path}"
        ) from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MeetingMemoryGraphQualityError(
            f"{label} is not valid UTF-8 JSON"
        ) from error


def object_shape(value, path, required):
    if not isinstance(value, dict):
        raise MeetingMemoryGraphQualityError(f"{path} must be an object")
    required = set(required)
    missing = required - value.keys()
    extra = value.keys() - required
    if missing:
        raise MeetingMemoryGraphQualityError(
            f"{path} is missing keys: {', '.join(sorted(missing))}"
        )
    if extra:
        raise MeetingMemoryGraphQualityError(
            f"{path} contains forbidden keys: {', '.join(sorted(extra))}"
        )
    return value


def safe_string(value, path, pattern=SAFE_ID):
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise MeetingMemoryGraphQualityError(f"{path} has an unsafe value")
    return value


def bounded_text(value, path, maximum=600):
    if not isinstance(value, str):
        raise MeetingMemoryGraphQualityError(f"{path} must be text")
    value = value.strip()
    if not value or len(value) > maximum or "\x00" in value:
        raise MeetingMemoryGraphQualityError(
            f"{path} must contain 1 to {maximum} safe characters"
        )
    return value


def enum_value(value, path, allowed):
    if value not in allowed:
        raise MeetingMemoryGraphQualityError(
            f"{path} must be one of: {', '.join(sorted(allowed))}"
        )
    return value


def integer(value, path, minimum=0, maximum=None):
    if isinstance(value, bool) or not isinstance(value, int):
        raise MeetingMemoryGraphQualityError(f"{path} must be an integer")
    if value < minimum or (maximum is not None and value > maximum):
        suffix = f" and <= {maximum}" if maximum is not None else ""
        raise MeetingMemoryGraphQualityError(
            f"{path} must be >= {minimum}{suffix}"
        )
    return value


def string_array(value, path, maximum_count=12):
    if not isinstance(value, list) or len(value) > maximum_count:
        raise MeetingMemoryGraphQualityError(
            f"{path} must be an array with at most {maximum_count} items"
        )
    result = [safe_string(item, f"{path}[{index}]") for index, item in enumerate(value)]
    if len(result) != len(set(result)):
        raise MeetingMemoryGraphQualityError(f"{path} must not contain duplicates")
    return result


def fixture_digest(document):
    encoded = json.dumps(
        document,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def query_language(relationship, job_index):
    if relationship in {"englishToEnglish", "englishToSpanish"}:
        return "en"
    if relationship in {"spanishToSpanish", "spanishToEnglish"}:
        return "es"
    if relationship == "codeSwitched":
        return "mixed"
    return "es" if job_index % 2 else "en"


def evidence_languages(relationship, job_index):
    if relationship in {"englishToEnglish", "spanishToEnglish"}:
        return ("en", "en", "en")
    if relationship in {"spanishToSpanish", "englishToSpanish"}:
        return ("es", "es", "es")
    if relationship == "codeSwitched":
        return ("en", "es", "mixed")
    language = "es" if job_index % 2 else "en"
    return (language, language, language)


def localized_text(job, stage, language, token):
    english = {
        "decisionHistory": (
            f"The team originally decided to batch {token} every hour.",
            f"The team confirmed that {token} will batch every ten minutes instead.",
            f"An unrelated archive for cobalt-{token[-3:]} remains monthly.",
        ),
        "changeSince": (
            f"At the previous meeting, {token} used the manual export.",
            f"Since then, {token} changed to the signed automatic export.",
            f"The unrelated office inventory did not change.",
        ),
        "personCommitments": (
            f"Mara completed the old {token} inventory.",
            f"Mara committed to send the {token} rollout checklist on Friday.",
            f"Noah committed to replace an unrelated projector.",
        ),
        "commitmentBlockers": (
            f"Mara confirmed the commitment to launch {token} on Friday.",
            f"The open retention decision explicitly blocks the {token} launch.",
            f"The office inventory was mentioned near {token}, without blocking it.",
        ),
        "firstDiscussion": (
            f"The team first introduced the term {token} for the telemetry envelope.",
            f"A later meeting revisited {token} after the prototype.",
            f"The unrelated term cobalt-{token[-3:]} appeared in another context.",
        ),
        "decisionConflicts": (
            f"The team confirmed that {token} would use hourly batches.",
            f"The team replaced that decision: {token} will use ten-minute batches.",
            f"A generated note guessed that {token} might stay hourly.",
        ),
    }
    spanish = {
        "decisionHistory": (
            f"El equipo decidió originalmente agrupar {token} cada hora.",
            f"El equipo confirmó que {token} se agrupará cada diez minutos.",
            f"Un archivo no relacionado de cobalt-{token[-3:]} seguirá mensual.",
        ),
        "changeSince": (
            f"En la reunión anterior, {token} usaba la exportación manual.",
            f"Desde entonces, {token} cambió a la exportación automática firmada.",
            "El inventario de oficina no relacionado no cambió.",
        ),
        "personCommitments": (
            f"Mara completó el inventario anterior de {token}.",
            f"Mara se comprometió a enviar la lista de lanzamiento de {token} el viernes.",
            "Noah se comprometió a reemplazar un proyector no relacionado.",
        ),
        "commitmentBlockers": (
            f"Mara confirmó el compromiso de lanzar {token} el viernes.",
            f"La decisión abierta de retención bloquea explícitamente el lanzamiento de {token}.",
            f"El inventario de oficina se mencionó cerca de {token}, sin bloquearlo.",
        ),
        "firstDiscussion": (
            f"El equipo introdujo por primera vez el término {token} para la envoltura de telemetría.",
            f"Una reunión posterior retomó {token} después del prototipo.",
            f"El término no relacionado cobalt-{token[-3:]} apareció en otro contexto.",
        ),
        "decisionConflicts": (
            f"El equipo confirmó que {token} usaría lotes cada hora.",
            f"El equipo reemplazó esa decisión: {token} usará lotes cada diez minutos.",
            f"Una nota generada supuso que {token} podría seguir cada hora.",
        ),
    }
    if language == "en":
        return english[job][stage]
    if language == "es":
        return spanish[job][stage]
    return f"{english[job][stage]} / {spanish[job][stage]}"


def question_text(job, language, token):
    english = {
        "decisionHistory": f"What did we decide about {token}?",
        "changeSince": f"What changed for {token} since the last meeting?",
        "personCommitments": f"What has Mara committed to for {token}?",
        "commitmentBlockers": f"Which open decisions block the {token} commitment?",
        "firstDiscussion": f"Where was {token} first discussed?",
        "decisionConflicts": f"Show contradictory or superseding decisions about {token} with sources.",
    }
    spanish = {
        "decisionHistory": f"¿Qué decidimos sobre {token}?",
        "changeSince": f"¿Qué cambió para {token} desde la última reunión?",
        "personCommitments": f"¿A qué se comprometió Mara para {token}?",
        "commitmentBlockers": f"¿Qué decisiones abiertas bloquean el compromiso de {token}?",
        "firstDiscussion": f"¿Dónde se habló por primera vez de {token}?",
        "decisionConflicts": f"Muestra decisiones contradictorias o reemplazadas sobre {token} con fuentes.",
    }
    if language == "en":
        return english[job]
    if language == "es":
        return spanish[job]
    return f"{english[job][:-1]} y dame las fuentes?"


def bilingual_text(english, spanish, language):
    if language == "en":
        return english
    if language == "es":
        return spanish
    return f"{english} / {spanish}"


def make_fact(identifier, kind, subject, predicate, obj, status, origin, evidence_ids):
    return {
        "id": identifier,
        "kind": kind,
        "subjectID": subject,
        "predicate": predicate,
        "objectID": obj,
        "status": status,
        "origin": origin,
        "evidenceIDs": evidence_ids,
        "stale": False,
    }


def answerable_facts(job, case_id, token, evidence_ids):
    first, second, distractor = evidence_ids
    prefix = f"fact-{case_id}"
    if job == "decisionHistory":
        facts = [
            make_fact(
                f"{prefix}-old", "decision", token, "decisionAbout",
                f"choice-{token}-hourly", "superseded", "confirmed", [first]),
            make_fact(
                f"{prefix}-current", "decision", token, "decisionAbout",
                f"choice-{token}-ten-minutes", "confirmed", "confirmed", [second]),
            make_fact(
                f"{prefix}-distractor", "decision", f"cobalt-{token[-3:]}",
                "decisionAbout", f"choice-cobalt-{token[-3:]}", "confirmed",
                "confirmed", [distractor]),
        ]
        return facts, [facts[1]["id"]], [second], [facts[0]["id"], facts[2]["id"]]
    if job == "changeSince":
        facts = [
            make_fact(
                f"{prefix}-baseline", "decision", token, "decisionAbout",
                f"export-{token}-manual", "confirmed", "confirmed", [first]),
            make_fact(
                f"{prefix}-change", "relation", f"export-{token}-signed",
                "changes", f"export-{token}-manual", "confirmed", "confirmed",
                [first, second]),
            make_fact(
                f"{prefix}-distractor", "relation", "office-inventory",
                "associatedWith", token, "observed", "generated", [distractor]),
        ]
        return facts, [facts[1]["id"]], [first, second], [facts[2]["id"]]
    if job == "personCommitments":
        facts = [
            make_fact(
                f"{prefix}-completed", "commitment", f"commitment-{token}-inventory",
                "committedTo", "person-mara", "completed", "manual", [first]),
            make_fact(
                f"{prefix}-open", "commitment", f"commitment-{token}-checklist",
                "committedTo", "person-mara", "open", "confirmed", [second]),
            make_fact(
                f"{prefix}-distractor", "commitment", "commitment-projector",
                "committedTo", "person-noah", "open", "confirmed", [distractor]),
        ]
        return facts, [facts[1]["id"]], [second], [facts[0]["id"], facts[2]["id"]]
    if job == "commitmentBlockers":
        facts = [
            make_fact(
                f"{prefix}-commitment", "commitment", f"commitment-{token}-launch",
                "committedTo", "person-mara", "open", "confirmed", [first]),
            make_fact(
                f"{prefix}-block", "relation", f"decision-{token}-retention",
                "blocks", f"commitment-{token}-launch", "confirmed", "confirmed",
                [first, second]),
            make_fact(
                f"{prefix}-distractor", "relation", "office-inventory",
                "associatedWith", f"commitment-{token}-launch", "observed",
                "generated", [distractor]),
        ]
        return facts, [facts[1]["id"]], [first, second], [facts[2]["id"]]
    if job == "firstDiscussion":
        facts = [
            make_fact(
                f"{prefix}-first", "topicMention", token, "discussed",
                f"meeting-{case_id}-1", "confirmed", "manual", [first]),
            make_fact(
                f"{prefix}-later", "topicMention", token, "discussed",
                f"meeting-{case_id}-2", "confirmed", "confirmed", [second]),
            make_fact(
                f"{prefix}-distractor", "topicMention", f"cobalt-{token[-3:]}",
                "discussed", f"meeting-{case_id}-2", "confirmed", "confirmed",
                [distractor]),
        ]
        return facts, [facts[0]["id"]], [first], [facts[1]["id"], facts[2]["id"]]
    facts = [
        make_fact(
            f"{prefix}-old", "decision", token, "decisionAbout",
            f"choice-{token}-hourly", "superseded", "confirmed", [first]),
        make_fact(
            f"{prefix}-new", "decision", token, "decisionAbout",
            f"choice-{token}-ten-minutes", "confirmed", "confirmed", [second]),
        make_fact(
            f"{prefix}-supersedes", "relation", f"{prefix}-new", "supersedes",
            f"{prefix}-old", "confirmed", "confirmed", [first, second]),
        make_fact(
            f"{prefix}-guess", "relation", f"{prefix}-old", "contradicts",
            f"{prefix}-new", "observed", "generated", [distractor]),
    ]
    return facts, [facts[2]["id"]], [first, second], [facts[3]["id"]]


def make_case(index, job, relationship, job_index):
    case_id = f"case-{index:03d}"
    token = f"atlas-{index:03d}"
    meeting_ids = [f"meeting-{case_id}-1", f"meeting-{case_id}-2"]
    languages = evidence_languages(relationship, job_index)
    evidence = []
    for stage in range(3):
        meeting_id = meeting_ids[0] if stage == 0 else meeting_ids[1]
        evidence.append({
            "id": f"evidence-{case_id}-{stage + 1}",
            "meetingID": meeting_id,
            "segmentID": f"segment-{case_id}-{stage + 1}",
            "transcriptRevision": 1,
            "timestampMilliseconds": (stage + 1) * 1_000,
            "language": languages[stage],
            "text": localized_text(job, stage, languages[stage], token),
        })
    facts, result_ids, expected_evidence, forbidden_ids = answerable_facts(
        job,
        case_id,
        token,
        [item["id"] for item in evidence],
    )
    expected = {
        "answerPolicy": "answer",
        "resultIDs": result_ids,
        "evidenceIDs": expected_evidence,
        "forbiddenResultIDs": forbidden_ids,
        "abstentionReason": None,
    }
    meetings = [
        {"id": meeting_ids[0], "sequence": 1, "title": f"{token} baseline"},
        {"id": meeting_ids[1], "sequence": 2, "title": f"{token} follow-up"},
    ]

    if relationship == "abstention":
        expected["answerPolicy"] = "abstain"
        expected["resultIDs"] = []
        expected["evidenceIDs"] = []
        expected["forbiddenResultIDs"] = [fact["id"] for fact in facts]
        expected["abstentionReason"] = ABSTENTION_REASON_BY_JOB[job]
        if job == "decisionHistory":
            for fact in facts:
                if fact["kind"] == "decision":
                    fact["origin"] = "generated"
                    fact["status"] = "observed"
            evidence[0]["text"] = bilingual_text(
                f"An unverified generated note claimed that {token} might batch hourly.",
                f"Una nota generada sin verificar afirmó que {token} podría agruparse cada hora.",
                evidence[0]["language"],
            )
            evidence[1]["text"] = bilingual_text(
                f"A generated note guessed that {token} might use ten-minute batches.",
                f"Una nota generada supuso que {token} podría usar lotes cada diez minutos.",
                evidence[1]["language"],
            )
        elif job == "changeSince":
            meetings = meetings[1:]
            evidence = evidence[1:]
            facts = [facts[1], facts[2]]
            facts[0]["evidenceIDs"] = [evidence[0]["id"]]
            expected["forbiddenResultIDs"] = [fact["id"] for fact in facts]
        elif job == "personCommitments":
            facts[1]["objectID"] = "person-alex-a"
            facts[2]["objectID"] = "person-alex-b"
            evidence[1]["text"] = bilingual_text(
                f"Alex committed to send the {token} rollout checklist.",
                f"Alex se comprometió a enviar la lista de lanzamiento de {token}.",
                evidence[1]["language"],
            )
            evidence[2]["text"] = bilingual_text(
                "A different Alex committed to replace the projector.",
                "Otra persona llamada Alex se comprometió a reemplazar el proyector.",
                evidence[2]["language"],
            )
        elif job == "commitmentBlockers":
            facts[1]["predicate"] = "associatedWith"
            facts[1]["origin"] = "generated"
            facts[1]["status"] = "observed"
            evidence[1]["text"] = bilingual_text(
                f"The retention decision was mentioned near {token}, without a stated dependency.",
                f"La decisión de retención se mencionó cerca de {token}, sin declarar una dependencia.",
                evidence[1]["language"],
            )
        elif job == "firstDiscussion":
            for fact in facts:
                if fact["kind"] == "topicMention":
                    fact["stale"] = True
        else:
            facts[2]["origin"] = "generated"
            facts[2]["status"] = "observed"
            facts[1]["origin"] = "generated"
            facts[1]["status"] = "observed"
            evidence[1]["text"] = bilingual_text(
                f"A generated note proposed ten-minute batches for {token}, but nobody confirmed a replacement.",
                f"Una nota generada propuso lotes de diez minutos para {token}, pero nadie confirmó un reemplazo.",
                evidence[1]["language"],
            )

    query_language_value = query_language(relationship, job_index)
    query_value = question_text(job, query_language_value, token)
    if relationship == "abstention" and job == "personCommitments":
        query_value = bilingual_text(
            f"What has Alex committed to for {token}?",
            f"¿A qué se comprometió Alex para {token}?",
            query_language_value,
        )

    return {
        "id": case_id,
        "job": job,
        "relationship": relationship,
        "query": {
            "language": query_language_value,
            "text": query_value,
        },
        "corpus": {
            "meetings": meetings,
            "evidence": evidence,
            "facts": facts,
        },
        "expected": expected,
    }


def public_fixture():
    cases = []
    index = 1
    for job_index, job in enumerate(JOBS):
        for relationship in RELATIONSHIPS:
            cases.append(make_case(index, job, relationship, job_index))
            index += 1
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": FIXTURE_KIND,
        "generation": GENERATION,
        "contentSource": CONTENT_SOURCE,
        "jobs": list(JOB_DEFINITIONS),
        "cases": cases,
    }


def validate_jobs(raw_jobs):
    if raw_jobs != list(JOB_DEFINITIONS):
        raise MeetingMemoryGraphQualityError(
            "fixture.jobs must match the query-first job contract"
        )


def validate_meetings(raw_meetings, path):
    if not isinstance(raw_meetings, list) or not raw_meetings:
        raise MeetingMemoryGraphQualityError(f"{path} must be a nonempty array")
    meetings = {}
    previous_sequence = 0
    for index, raw in enumerate(raw_meetings):
        item_path = f"{path}[{index}]"
        meeting = object_shape(raw, item_path, ("id", "sequence", "title"))
        identifier = safe_string(meeting["id"], f"{item_path}.id")
        if identifier in meetings:
            raise MeetingMemoryGraphQualityError(f"{path} contains duplicate IDs")
        sequence = integer(meeting["sequence"], f"{item_path}.sequence", 1, 20)
        if sequence <= previous_sequence:
            raise MeetingMemoryGraphQualityError(f"{path} must be ordered by sequence")
        previous_sequence = sequence
        bounded_text(meeting["title"], f"{item_path}.title", 160)
        meetings[identifier] = meeting
    return meetings


def validate_evidence(raw_evidence, meetings, path):
    if not isinstance(raw_evidence, list) or not raw_evidence:
        raise MeetingMemoryGraphQualityError(f"{path} must be a nonempty array")
    evidence = {}
    for index, raw in enumerate(raw_evidence):
        item_path = f"{path}[{index}]"
        item = object_shape(
            raw,
            item_path,
            (
                "id",
                "meetingID",
                "segmentID",
                "transcriptRevision",
                "timestampMilliseconds",
                "language",
                "text",
            ),
        )
        identifier = safe_string(item["id"], f"{item_path}.id")
        if identifier in evidence:
            raise MeetingMemoryGraphQualityError(f"{path} contains duplicate IDs")
        meeting_id = safe_string(item["meetingID"], f"{item_path}.meetingID")
        if meeting_id not in meetings:
            raise MeetingMemoryGraphQualityError(
                f"{item_path}.meetingID does not exist in the case corpus"
            )
        safe_string(item["segmentID"], f"{item_path}.segmentID")
        integer(item["transcriptRevision"], f"{item_path}.transcriptRevision", 1)
        integer(item["timestampMilliseconds"], f"{item_path}.timestampMilliseconds")
        enum_value(item["language"], f"{item_path}.language", LANGUAGES)
        bounded_text(item["text"], f"{item_path}.text")
        evidence[identifier] = item
    return evidence


def validate_facts(raw_facts, evidence, path):
    if not isinstance(raw_facts, list) or not raw_facts:
        raise MeetingMemoryGraphQualityError(f"{path} must be a nonempty array")
    facts = {}
    for index, raw in enumerate(raw_facts):
        item_path = f"{path}[{index}]"
        fact = object_shape(
            raw,
            item_path,
            (
                "id",
                "kind",
                "subjectID",
                "predicate",
                "objectID",
                "status",
                "origin",
                "evidenceIDs",
                "stale",
            ),
        )
        identifier = safe_string(fact["id"], f"{item_path}.id")
        if identifier in facts:
            raise MeetingMemoryGraphQualityError(f"{path} contains duplicate IDs")
        enum_value(fact["kind"], f"{item_path}.kind", FACT_KINDS)
        safe_string(fact["subjectID"], f"{item_path}.subjectID")
        enum_value(fact["predicate"], f"{item_path}.predicate", PREDICATES)
        safe_string(fact["objectID"], f"{item_path}.objectID")
        enum_value(fact["status"], f"{item_path}.status", STATUSES)
        enum_value(fact["origin"], f"{item_path}.origin", ORIGINS)
        evidence_ids = string_array(fact["evidenceIDs"], f"{item_path}.evidenceIDs")
        if not evidence_ids:
            raise MeetingMemoryGraphQualityError(
                f"{item_path}.evidenceIDs must not be empty"
            )
        if any(item not in evidence for item in evidence_ids):
            raise MeetingMemoryGraphQualityError(
                f"{item_path}.evidenceIDs must exist in the case corpus"
            )
        if not isinstance(fact["stale"], bool):
            raise MeetingMemoryGraphQualityError(f"{item_path}.stale must be boolean")
        facts[identifier] = fact
    return facts


def validate_expected(raw_expected, job, facts, evidence, path):
    expected = object_shape(
        raw_expected,
        path,
        (
            "answerPolicy",
            "resultIDs",
            "evidenceIDs",
            "forbiddenResultIDs",
            "abstentionReason",
        ),
    )
    policy = enum_value(
        expected["answerPolicy"], f"{path}.answerPolicy", {"answer", "abstain"}
    )
    result_ids = string_array(expected["resultIDs"], f"{path}.resultIDs")
    evidence_ids = string_array(expected["evidenceIDs"], f"{path}.evidenceIDs")
    forbidden_ids = string_array(
        expected["forbiddenResultIDs"], f"{path}.forbiddenResultIDs"
    )
    for collection, label, authority in (
        (result_ids, "resultIDs", facts),
        (forbidden_ids, "forbiddenResultIDs", facts),
        (evidence_ids, "evidenceIDs", evidence),
    ):
        if any(identifier not in authority for identifier in collection):
            raise MeetingMemoryGraphQualityError(
                f"{path}.{label} must reference the case corpus"
            )
    if set(result_ids) & set(forbidden_ids):
        raise MeetingMemoryGraphQualityError(
            f"{path} cannot require and forbid the same result"
        )
    if not forbidden_ids:
        raise MeetingMemoryGraphQualityError(
            f"{path}.forbiddenResultIDs must name unsupported temptations"
        )
    if policy == "answer":
        if not result_ids or not evidence_ids:
            raise MeetingMemoryGraphQualityError(
                f"{path} answer cases require results and exact evidence"
            )
        if expected["abstentionReason"] is not None:
            raise MeetingMemoryGraphQualityError(
                f"{path}.abstentionReason must be null for answer cases"
            )
        allowed_kinds = next(
            definition["allowedResultKinds"]
            for definition in JOB_DEFINITIONS
            if definition["id"] == job
        )
        for identifier in result_ids:
            fact = facts[identifier]
            if fact["kind"] not in allowed_kinds:
                raise MeetingMemoryGraphQualityError(
                    f"{path}.resultIDs contain a kind outside the job contract"
                )
            if (
                fact["stale"]
                or fact["origin"] == "generated"
                or fact["status"] not in CURRENT_RESULT_STATUSES[fact["kind"]]
            ):
                raise MeetingMemoryGraphQualityError(
                    f"{path}.resultIDs must be current confirmed/manual truth"
                )
        supported_evidence = {
            evidence_id
            for identifier in result_ids
            for evidence_id in facts[identifier]["evidenceIDs"]
        }
        if set(evidence_ids) != supported_evidence:
            raise MeetingMemoryGraphQualityError(
                f"{path}.evidenceIDs must exactly support the required results"
            )
    else:
        if result_ids or evidence_ids:
            raise MeetingMemoryGraphQualityError(
                f"{path} abstention cases require only forbidden temptations"
            )
        enum_value(
            expected["abstentionReason"],
            f"{path}.abstentionReason",
            ABSTENTION_REASONS,
        )
        if expected["abstentionReason"] != ABSTENTION_REASON_BY_JOB[job]:
            raise MeetingMemoryGraphQualityError(
                f"{path}.abstentionReason does not match the job contract"
            )


def validate_abstention_semantics(job, expected, meetings, facts, path):
    if expected["answerPolicy"] != "abstain":
        return
    reason = expected["abstentionReason"]
    if reason == "insufficientConfirmedDecision" and any(
        fact["kind"] == "decision"
        and fact["origin"] != "generated"
        and fact["status"] == "confirmed"
        and not fact["stale"]
        for fact in facts.values()
    ):
        raise MeetingMemoryGraphQualityError(f"{path} has confirmed decision truth")
    if reason == "missingTemporalBaseline" and len(meetings) != 1:
        raise MeetingMemoryGraphQualityError(f"{path} must omit the temporal baseline")
    if reason == "ambiguousPerson":
        people = {
            fact["objectID"]
            for fact in facts.values()
            if fact["kind"] == "commitment" and fact["status"] == "open"
        }
        if len(people) < 2:
            raise MeetingMemoryGraphQualityError(f"{path} must retain person ambiguity")
    if reason == "unsupportedCausalLink" and any(
        fact["kind"] == "relation"
        and fact["predicate"] == "blocks"
        and fact["origin"] != "generated"
        and not fact["stale"]
        for fact in facts.values()
    ):
        raise MeetingMemoryGraphQualityError(f"{path} has supported causal truth")
    if reason == "staleEvidenceOnly" and any(
        fact["kind"] == "topicMention" and not fact["stale"]
        for fact in facts.values()
    ):
        raise MeetingMemoryGraphQualityError(f"{path} has current topic evidence")
    if reason == "unsupportedConflict" and any(
        fact["kind"] == "relation"
        and fact["predicate"] in {"supersedes", "contradicts"}
        and fact["origin"] != "generated"
        and fact["status"] == "confirmed"
        and not fact["stale"]
        for fact in facts.values()
    ):
        raise MeetingMemoryGraphQualityError(f"{path} has supported conflict truth")


def validate_relationship(case, evidence, path):
    relationship = case["relationship"]
    query_language_value = case["query"]["language"]
    languages = {item["language"] for item in evidence.values()}
    expected = {
        "englishToEnglish": ("en", {"en"}),
        "spanishToSpanish": ("es", {"es"}),
        "englishToSpanish": ("en", {"es"}),
        "spanishToEnglish": ("es", {"en"}),
    }
    if relationship in expected:
        query_language_expected, evidence_languages_expected = expected[relationship]
        if query_language_value != query_language_expected or languages != evidence_languages_expected:
            raise MeetingMemoryGraphQualityError(
                f"{path} does not match its bilingual relationship"
            )
    if relationship == "codeSwitched" and (
        query_language_value != "mixed" or not {"en", "es"}.issubset(languages)
    ):
        raise MeetingMemoryGraphQualityError(
            f"{path} must contain code-switched query and evidence"
        )


def validate_fixture(document, exact_distribution=True):
    fixture = object_shape(
        document,
        "fixture",
        ("schemaVersion", "kind", "generation", "contentSource", "jobs", "cases"),
    )
    if integer(fixture["schemaVersion"], "fixture.schemaVersion") != SCHEMA_VERSION:
        raise MeetingMemoryGraphQualityError("fixture.schemaVersion must be 1")
    if fixture["kind"] != FIXTURE_KIND:
        raise MeetingMemoryGraphQualityError(f"fixture.kind must be {FIXTURE_KIND}")
    safe_string(fixture["generation"], "fixture.generation", SAFE_GENERATION)
    if fixture["contentSource"] != CONTENT_SOURCE:
        raise MeetingMemoryGraphQualityError(
            f"fixture.contentSource must be {CONTENT_SOURCE}"
        )
    validate_jobs(fixture["jobs"])
    if not isinstance(fixture["cases"], list) or not fixture["cases"]:
        raise MeetingMemoryGraphQualityError("fixture.cases must be a nonempty array")
    if len(fixture["cases"]) > 240:
        raise MeetingMemoryGraphQualityError("fixture.cases exceeds the bound")

    case_ids = set()
    meeting_ids = set()
    evidence_ids = set()
    fact_ids = set()
    job_counts = {job: 0 for job in JOBS}
    relationship_counts = {relationship: 0 for relationship in RELATIONSHIPS}
    abstention_counts = {reason: 0 for reason in ABSTENTION_REASONS}
    for index, raw_case in enumerate(fixture["cases"]):
        path = f"fixture.cases[{index}]"
        case = object_shape(
            raw_case,
            path,
            ("id", "job", "relationship", "query", "corpus", "expected"),
        )
        identifier = safe_string(case["id"], f"{path}.id")
        if identifier in case_ids:
            raise MeetingMemoryGraphQualityError("fixture.cases contains duplicate IDs")
        case_ids.add(identifier)
        job = enum_value(case["job"], f"{path}.job", set(JOBS))
        relationship = enum_value(
            case["relationship"], f"{path}.relationship", set(RELATIONSHIPS)
        )
        query = object_shape(case["query"], f"{path}.query", ("language", "text"))
        enum_value(query["language"], f"{path}.query.language", LANGUAGES)
        bounded_text(query["text"], f"{path}.query.text", 240)
        corpus = object_shape(
            case["corpus"], f"{path}.corpus", ("meetings", "evidence", "facts")
        )
        meetings = validate_meetings(corpus["meetings"], f"{path}.corpus.meetings")
        evidence = validate_evidence(
            corpus["evidence"], meetings, f"{path}.corpus.evidence"
        )
        facts = validate_facts(corpus["facts"], evidence, f"{path}.corpus.facts")
        for label, identifiers, seen in (
            ("meeting", set(meetings), meeting_ids),
            ("evidence", set(evidence), evidence_ids),
            ("fact", set(facts), fact_ids),
        ):
            if seen & identifiers:
                raise MeetingMemoryGraphQualityError(
                    f"{path} must keep {label} IDs isolated across cases"
                )
            seen.update(identifiers)
        validate_expected(case["expected"], job, facts, evidence, f"{path}.expected")
        validate_abstention_semantics(job, case["expected"], meetings, facts, path)
        validate_relationship(case, evidence, path)
        job_counts[job] += 1
        relationship_counts[relationship] += 1
        reason = case["expected"]["abstentionReason"]
        if reason is not None:
            abstention_counts[reason] += 1

    if exact_distribution and (
        job_counts != JOB_COUNTS
        or relationship_counts != RELATIONSHIP_COUNTS
        or any(count != 1 for count in abstention_counts.values())
    ):
        raise MeetingMemoryGraphQualityError(
            "fixture distribution must be exactly six jobs by six relationships "
            "with one abstention reason per job"
        )
    return {
        "caseCount": len(fixture["cases"]),
        "jobCounts": job_counts,
        "relationshipCounts": relationship_counts,
        "abstentionReasonCounts": abstention_counts,
        "generation": fixture["generation"],
        "contentSource": fixture["contentSource"],
        "checksum": fixture_digest(fixture),
    }


def write_json(path, document):
    path = Path(path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main_from_args(arguments):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate = subparsers.add_parser("generate")
    generate.add_argument("--output", required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--fixture", required=True)
    verify = subparsers.add_parser("verify-public")
    verify.add_argument("--fixture", required=True)
    args = parser.parse_args(arguments)

    if args.command == "generate":
        document = public_fixture()
        validate_fixture(document)
        write_json(args.output, document)
        return 0

    document = load_json(args.fixture, "fixture")
    summary = validate_fixture(document)
    if args.command == "verify-public" and document != public_fixture():
        raise MeetingMemoryGraphQualityError(
            "public Meeting Memory Graph fixture is not canonical"
        )
    print(json.dumps({
        "caseCount": summary["caseCount"],
        "generation": summary["generation"],
        "kind": FIXTURE_KIND,
        "sha256": summary["checksum"],
    }, sort_keys=True))
    return 0


def main():
    try:
        return main_from_args(sys.argv[1:])
    except MeetingMemoryGraphQualityError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
