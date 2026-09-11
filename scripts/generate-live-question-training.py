#!/usr/bin/env python3
"""Generate the frozen public-synthetic LIVE-1 question training corpus."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


GENERATION = "public-synthetic-bilingual-v1"


def combinations(templates: list[str], values: list[str]) -> list[str]:
    return [template.format(value=value) for template in templates for value in values]


def build_examples() -> dict[str, list[str]]:
    english_topics = [
        "the retry queue stopped",
        "the release date changed",
        "the signed receipt is missing",
        "the database migration is slow",
        "the customer cannot sign in",
        "the audio capture lost a channel",
        "the deployment rolled back",
        "the search index is stale",
        "the memory graph is inconsistent",
        "the build fails on Sequoia",
        "the transcript has duplicate rows",
        "the request exceeded its timeout",
    ]
    spanish_topics = [
        "la cola de reintentos se detuvo",
        "cambió la fecha del lanzamiento",
        "falta el recibo firmado",
        "la migración de la base de datos es lenta",
        "el cliente no puede iniciar sesión",
        "la captura de audio perdió un canal",
        "el despliegue volvió atrás",
        "el índice de búsqueda está desactualizado",
        "el grafo de memoria es inconsistente",
        "la compilación falla en Sequoia",
        "la transcripción tiene filas duplicadas",
        "la solicitud superó el tiempo de espera",
    ]

    question = combinations(
        [
            "Can you explain why {value}?",
            "How should we fix that {value}?",
            "Do we know why {value}?",
            "What evidence shows that {value}?",
            "Where did we record that {value}?",
            "Could you tell us when {value}?",
            "Alex, tell us why {value}.",
            "Alex, what changed after {value}?",
            "We need an answer: why did {value}?",
            "Is it expected that {value}?",
        ],
        english_topics,
    )
    question += combinations(
        [
            "¿Puedes explicar por qué {value}?",
            "¿Cómo deberíamos corregir que {value}?",
            "¿Sabemos por qué {value}?",
            "¿Qué evidencia muestra que {value}?",
            "¿Dónde registramos que {value}?",
            "¿Podrías decirnos cuándo {value}?",
            "Alex, cuéntanos por qué {value}.",
            "Alex, ¿qué cambió después de que {value}?",
            "Necesitamos una respuesta: ¿por qué {value}?",
            "¿Es esperable que {value}?",
        ],
        spanish_topics,
    )
    question += [
        "can yu explain why the worker stopd",
        "wher shud we save the audit recipt",
        "how do we recover the pendin proces",
        "alex tell us bout the failed deploy",
        "did the retri run after relaunch",
        "what changed in la politica de cache",
        "can you confirmar when the release closes",
        "como do we recover the pending job",
        "alex nos dices what failed in production",
        "where guardamos el resultado firmado",
        "donde debemos guardar el recibo de auditoria",
        "como recuperamos el proceso pendiente",
        "alex cuentanos sobre el despliegue fallido",
        "se ejecuto el reintento despues de reiniciar",
        "por que la cola dejo de responder",
        "quien valida el cambio antes del release",
    ]

    non_question = combinations(
        [
            "The team confirmed that {value}.",
            "Yesterday we learned that {value}.",
            "Our current status is that {value}.",
            "The incident report says that {value}.",
            "After the review, {value}.",
            "Please record that {value}.",
            "I already explained why {value}.",
            "We will investigate whether {value}.",
            "The next agenda item covers why {value}.",
            "Everyone agreed that {value}.",
        ],
        english_topics,
    )
    non_question += combinations(
        [
            "El equipo confirmó que {value}.",
            "Ayer supimos que {value}.",
            "El estado actual es que {value}.",
            "El informe del incidente dice que {value}.",
            "Después de la revisión, {value}.",
            "Por favor registra que {value}.",
            "Ya expliqué por qué {value}.",
            "Investigaremos si {value}.",
            "El siguiente punto explica por qué {value}.",
            "Todos acordaron que {value}.",
        ],
        spanish_topics,
    )
    non_question += [
        "What an excellent result the team achieved today.",
        "How wonderful that the migration finished early.",
        "What a difficult incident we resolved together.",
        "Could have been worse after that rollback.",
        "Can do the follow-up after lunch.",
        "Alex presented the revised retry policy.",
        "The answer is stored in the signed release notes.",
        "We discussed how the cache invalidation works.",
        "That explains why the queue stopped.",
        "I wonder whether the customer saw the warning.",
        "Qué gran resultado logró el equipo hoy.",
        "Qué bueno que la migración terminó temprano.",
        "Qué incidente tan difícil resolvimos juntos.",
        "Podría haber sido peor después del rollback.",
        "Podemos hacer el seguimiento después del almuerzo.",
        "Alex presentó la política de reintentos revisada.",
        "La respuesta está en las notas firmadas del lanzamiento.",
        "Hablamos de cómo funciona la invalidación del caché.",
        "Eso explica por qué se detuvo la cola.",
        "Me pregunto si el cliente vio la advertencia.",
    ]

    abstain = [
        "Could the worker retry",
        "Can the",
        "What about",
        "Why did",
        "Where should",
        "Alex, could you",
        "Maybe the question is",
        "The FAQ heading says how do deployments work?",
        "The document quotes: why did the job fail?",
        "The ticket title is 'Can we recover the index?'",
        "I wrote down the question what should we ship next.",
        "The slide contains a question mark but no one asked it.",
        "She asked yesterday whether the receipt was valid.",
        "He repeated the customer's question about the timeout.",
        "The agenda includes 'How do we reduce latency?'",
        "We should remember the phrase why now and not later.",
        "Uh what no",
        "Can we maybe",
        "How would it",
        "What if the",
        "Podría el reintento",
        "Podemos tal vez",
        "Qué pasa con",
        "Por qué se",
        "Dónde deberíamos",
        "Alex, podrías",
        "Tal vez la pregunta es",
        "El título de preguntas frecuentes dice ¿cómo desplegamos?",
        "El documento cita: ¿por qué falló el proceso?",
        "El ticket se titula '¿Podemos recuperar el índice?'",
        "Anoté la pregunta qué deberíamos publicar después.",
        "La diapositiva tiene una pregunta, pero nadie la hizo.",
        "Ella preguntó ayer si el recibo era válido.",
        "Repitió la pregunta del cliente sobre el timeout.",
        "La agenda incluye '¿Cómo reducimos la latencia?'",
        "Debemos recordar la frase por qué ahora y no después.",
        "Eh qué no",
        "Podríamos quizás",
        "Cómo sería si",
        "Qué pasa si el",
        "the doc says ¿como do we deploy? but nobody asked",
        "el ticket copia why did it fail pero es solo un titulo",
        "maybe podemos ask",
        "could we tal vez",
    ]

    return {
        "question": sorted(set(question)),
        "nonQuestion": sorted(set(non_question)),
        "abstain": sorted(set(abstain)),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    options = parser.parse_args()
    examples = build_examples()
    payload = {
        "schemaVersion": 1,
        "kind": "live-question-training-corpus",
        "generation": GENERATION,
        "contentSource": "public-synthetic-only",
        "license": "CC0-1.0",
        "labels": examples,
    }
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    counts = ", ".join(f"{key}={len(value)}" for key, value in examples.items())
    print(f"generated {options.output}: {counts}")


if __name__ == "__main__":
    main()
