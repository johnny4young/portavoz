#!/usr/bin/env python3
"""Generate and verify Portavoz's public retrieval-chunk resource fixture."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import defaultdict
from pathlib import Path


SCHEMA_VERSION = 1
FIXTURE_KIND = "retrieval-chunk-resource-fixture"
PUBLIC_GENERATION = "public-bilingual-homogeneous-v1"
PUBLIC_SOURCE = "public-synthetic-only"
MEETING_COUNT = 60
SEGMENTS_PER_MEETING = 8
TURNS_PER_MEETING = 4
SEGMENTS_PER_TURN = 2
ENGLISH_TURN_COUNT = 120
SPANISH_TURN_COUNT = 120
SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")
MAXIMUM_BYTES = 8 * 1024 * 1024


class RetrievalChunkResourceFixtureError(ValueError):
    """A fail-closed public fixture contract violation."""


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise RetrievalChunkResourceFixtureError(f"duplicate key: {key}")
        result[key] = value
    return result


def reject_nonstandard_constant(value):
    raise RetrievalChunkResourceFixtureError(
        f"nonstandard JSON constant is not allowed: {value}"
    )


def load_json_snapshot(path, label="retrieval chunk resource fixture"):
    path = Path(path).expanduser()
    try:
        if not path.is_file():
            raise RetrievalChunkResourceFixtureError(f"{label} not found: {path}")
        with path.open("rb") as handle:
            data = handle.read(MAXIMUM_BYTES + 1)
        if len(data) > MAXIMUM_BYTES:
            raise RetrievalChunkResourceFixtureError(f"{label} exceeds 8 MiB")
        document = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_nonstandard_constant,
        )
        return document, data
    except OSError as error:
        raise RetrievalChunkResourceFixtureError(
            f"{label} could not be read: {path}"
        ) from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RetrievalChunkResourceFixtureError(
            f"{label} is not valid UTF-8 JSON"
        ) from error


def load_json(path, label="retrieval chunk resource fixture"):
    return load_json_snapshot(path, label)[0]


def require_shape(value, keys, label):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise RetrievalChunkResourceFixtureError(f"{label} has an invalid shape")
    return value


def require_safe_id(value, label):
    if not isinstance(value, str) or SAFE_ID.fullmatch(value) is None:
        raise RetrievalChunkResourceFixtureError(f"{label} is not a safe identifier")
    return value


def require_text(value, label, maximum):
    if (
        not isinstance(value, str)
        or not value.strip()
        or len(value) > maximum
        or "\x00" in value
    ):
        raise RetrievalChunkResourceFixtureError(
            f"{label} must contain 1 to {maximum} safe characters"
        )
    return value


def require_integer(value, label, minimum=0):
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise RetrievalChunkResourceFixtureError(
            f"{label} must be an integer >= {minimum}"
        )
    return value


def public_fixture():
    owners = ("Avery", "Blake", "Carmen", "Diego")
    segments = []
    for meeting_index in range(1, MEETING_COUNT + 1):
        meeting_id = f"resource-meeting-{meeting_index:03d}"
        marker = f"resource-{meeting_index:03d}"
        texts = (
            (
                f"Avery reviewed the public synthetic plan for {marker}.",
                f"Avery confirmed the public schedule for {marker}.",
            ),
            (
                f"Blake documented the public synthetic risks for {marker}.",
                f"Blake confirmed the public mitigation for {marker}.",
            ),
            (
                f"Carmen revisó el plan público sintético para {marker}.",
                f"Carmen confirmó el calendario público para {marker}.",
            ),
            (
                f"Diego documentó los riesgos públicos sintéticos de {marker}.",
                f"Diego confirmó la mitigación pública de {marker}.",
            ),
        )
        for turn_index, owner in enumerate(owners):
            language = "en" if turn_index < 2 else "es"
            for source_index in range(SEGMENTS_PER_TURN):
                ordinal = turn_index * SEGMENTS_PER_TURN + source_index + 1
                segments.append(
                    {
                        "id": f"resource-segment-{meeting_index:03d}-{ordinal:02d}",
                        "meetingID": meeting_id,
                        "meetingTitle": (
                            f"Public retrieval resource meeting {meeting_index:03d}"
                        ),
                        "timestampMilliseconds": ordinal * 1_000,
                        "transcriptRevision": 1,
                        "language": language,
                        "owner": owner,
                        "text": texts[turn_index][source_index],
                    }
                )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": FIXTURE_KIND,
        "generation": PUBLIC_GENERATION,
        "contentSource": PUBLIC_SOURCE,
        "segments": segments,
    }


def validate_fixture(document):
    fixture = require_shape(
        document,
        ("schemaVersion", "kind", "generation", "contentSource", "segments"),
        "fixture",
    )
    if fixture["schemaVersion"] != SCHEMA_VERSION:
        raise RetrievalChunkResourceFixtureError("fixture schema is unsupported")
    if fixture["kind"] != FIXTURE_KIND:
        raise RetrievalChunkResourceFixtureError("fixture kind is unsupported")
    if fixture["generation"] != PUBLIC_GENERATION:
        raise RetrievalChunkResourceFixtureError("fixture generation is unsupported")
    if fixture["contentSource"] != PUBLIC_SOURCE:
        raise RetrievalChunkResourceFixtureError("fixture source must be public synthetic")
    raw_segments = fixture["segments"]
    if not isinstance(raw_segments, list) or len(raw_segments) != (
        MEETING_COUNT * SEGMENTS_PER_MEETING
    ):
        raise RetrievalChunkResourceFixtureError("fixture segment coverage changed")

    segments_by_meeting = defaultdict(list)
    identities = set()
    segment_keys = (
        "id",
        "meetingID",
        "meetingTitle",
        "timestampMilliseconds",
        "transcriptRevision",
        "language",
        "owner",
        "text",
    )
    for index, raw in enumerate(raw_segments):
        label = f"fixture.segments[{index}]"
        segment = require_shape(raw, segment_keys, label)
        identifier = require_safe_id(segment["id"], f"{label}.id")
        if identifier in identities:
            raise RetrievalChunkResourceFixtureError(
                f"fixture repeats segment identity: {identifier}"
            )
        identities.add(identifier)
        meeting_id = require_safe_id(segment["meetingID"], f"{label}.meetingID")
        require_text(segment["meetingTitle"], f"{label}.meetingTitle", 200)
        require_integer(
            segment["timestampMilliseconds"], f"{label}.timestampMilliseconds"
        )
        require_integer(
            segment["transcriptRevision"], f"{label}.transcriptRevision", 1
        )
        if segment["language"] not in {"en", "es"}:
            raise RetrievalChunkResourceFixtureError(
                f"{label}.language must be en or es"
            )
        require_text(segment["owner"], f"{label}.owner", 120)
        require_text(segment["text"], f"{label}.text", 2_000)
        segments_by_meeting[meeting_id].append(segment)

    if len(segments_by_meeting) != MEETING_COUNT:
        raise RetrievalChunkResourceFixtureError("fixture meeting coverage changed")

    language_turn_counts = {"en": 0, "es": 0}
    for meeting_id in sorted(segments_by_meeting):
        meeting = segments_by_meeting[meeting_id]
        if len(meeting) != SEGMENTS_PER_MEETING:
            raise RetrievalChunkResourceFixtureError(
                f"{meeting_id} must contain {SEGMENTS_PER_MEETING} segments"
            )
        ordered = sorted(
            meeting,
            key=lambda item: (item["timestampMilliseconds"], item["id"]),
        )
        if meeting != ordered:
            raise RetrievalChunkResourceFixtureError(
                f"{meeting_id} segments are not in canonical order"
            )
        if len({item["meetingTitle"] for item in meeting}) != 1:
            raise RetrievalChunkResourceFixtureError(
                f"{meeting_id} has inconsistent titles"
            )
        if len({item["transcriptRevision"] for item in meeting}) != 1:
            raise RetrievalChunkResourceFixtureError(
                f"{meeting_id} has inconsistent transcript revisions"
            )
        timestamps = [item["timestampMilliseconds"] for item in meeting]
        if any(current >= following for current, following in zip(timestamps, timestamps[1:])):
            raise RetrievalChunkResourceFixtureError(
                f"{meeting_id} timestamps must increase strictly"
            )

        turns = []
        for segment in meeting:
            if turns and turns[-1][0] == segment["owner"]:
                if turns[-1][1] != segment["language"]:
                    raise RetrievalChunkResourceFixtureError(
                        f"{meeting_id} contains a mixed-language complete turn"
                    )
                turns[-1][2].append(segment)
            else:
                turns.append([segment["owner"], segment["language"], [segment]])
        if len(turns) != TURNS_PER_MEETING:
            raise RetrievalChunkResourceFixtureError(
                f"{meeting_id} must contain {TURNS_PER_MEETING} complete turns"
            )
        if len({turn[0] for turn in turns}) != TURNS_PER_MEETING:
            raise RetrievalChunkResourceFixtureError(
                f"{meeting_id} must preserve four distinct actors"
            )
        for _, language, sources in turns:
            if len(sources) != SEGMENTS_PER_TURN:
                raise RetrievalChunkResourceFixtureError(
                    f"{meeting_id} turns must contain {SEGMENTS_PER_TURN} segments"
                )
            language_turn_counts[language] += 1

    if language_turn_counts != {
        "en": ENGLISH_TURN_COUNT,
        "es": SPANISH_TURN_COUNT,
    }:
        raise RetrievalChunkResourceFixtureError(
            "fixture must contain 120 homogeneous English and 120 homogeneous Spanish turns"
        )
    return {
        "meetingCount": len(segments_by_meeting),
        "sourceSegmentCount": len(raw_segments),
        "homogeneousEnglishTurnCount": language_turn_counts["en"],
        "homogeneousSpanishTurnCount": language_turn_counts["es"],
    }


def write_public_fixture(path):
    path = Path(path).expanduser()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("x", encoding="utf-8") as handle:
            handle.write(
                json.dumps(
                    public_fixture(),
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
                + "\n"
            )
    except FileExistsError as error:
        raise RetrievalChunkResourceFixtureError(
            f"public fixture already exists: {path}"
        ) from error
    except OSError as error:
        raise RetrievalChunkResourceFixtureError(
            f"public fixture could not be written: {path}"
        ) from error


def verify_public_fixture(path):
    actual, data = load_json_snapshot(path)
    validate_fixture(actual)
    if actual != public_fixture():
        raise RetrievalChunkResourceFixtureError(
            "public retrieval chunk resource fixture is not canonical"
        )
    return hashlib.sha256(data).hexdigest()


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate = subparsers.add_parser("generate-public")
    generate.add_argument("--output", type=Path, required=True)
    verify = subparsers.add_parser("verify-public")
    verify.add_argument("--fixture", type=Path, required=True)
    verify.add_argument("--print-sha256", action="store_true")
    return parser


def main_from_args(arguments):
    arguments = build_parser().parse_args(arguments)
    if arguments.command == "generate-public":
        write_public_fixture(arguments.output)
        return 0
    digest = verify_public_fixture(arguments.fixture)
    if arguments.print_sha256:
        print(digest)
    return 0


def main():
    try:
        return main_from_args(sys.argv[1:])
    except RetrievalChunkResourceFixtureError as error:
        print(f"retrieval-chunk-resource-fixture error: {error}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
