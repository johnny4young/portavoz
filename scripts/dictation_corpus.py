#!/usr/bin/env python3
"""Admit the public dictation corpus and exact local PCM assets, not quality claims."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import unicodedata
import wave

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "Fixtures/DictationValidation/public-synthetic-v1.json"
CORPUS_SHA256 = "92de308a11ea180e10f0120b41cf2c24e713b1f4e15dc26b50b55312ef3022e3"
GROUP_COUNTS = {"en": 20, "es": 20, "mixed": 10, "adversarial": 10}
SPLITS = {"tuning", "holdout"}
AUDIO_KINDS = {"speech", "silence", "noise", "tone", "impulses"}
IDENTIFIER = re.compile(r"[a-z][a-z0-9-]{0,63}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
MAX_JSON_BYTES = 2_000_000
MAX_AUDIO_BYTES = 4_000_128


class CorpusError(ValueError):
    """Diagnostics must name a contract, never the rejected value or path."""


def require(condition, reason):
    if not condition:
        raise CorpusError(reason)


def exact_keys(value, keys, reason):
    require(type(value) is dict and set(value) == set(keys.split()), reason)


def integer(value, minimum, maximum):
    return type(value) is int and minimum <= value <= maximum


def digest(value):
    return type(value) is str and DIGEST.fullmatch(value) is not None


def identifier(value):
    return type(value) is str and IDENTIFIER.fullmatch(value) is not None


def choice(value, choices):
    return type(value) is str and value in choices


def text(value, *, empty=False):
    if type(value) is not str or (not empty and not value.strip()):
        return False
    try:
        return len(value.encode("utf-8")) <= 8_000
    except UnicodeError:
        return False


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def reject_constant(_):
    raise CorpusError("non-finite JSON number")


def read_json(path, *, maximum_bytes=MAX_JSON_BYTES):
    require(integer(maximum_bytes, 1, 8_000_000), "invalid JSON input bound")
    try:
        with Path(path).open("rb") as stream:
            data = stream.read(maximum_bytes + 1)
        require(len(data) <= maximum_bytes, "JSON input exceeds bound")
        value = json.loads(data, object_pairs_hook=unique_pairs, parse_constant=reject_constant)
        return value, hashlib.sha256(data).hexdigest()
    except (OSError, UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise CorpusError("JSON input is unreadable or malformed") from error


def validate_family(family):
    exact_keys(family, "id group cohort shape split audioKind segments acceptedTexts critical", "family schema mismatch")
    require(identifier(family["id"]) and identifier(family["group"]) and identifier(family["shape"]),
            "invalid family identity")
    require(choice(family["cohort"], GROUP_COUNTS) and choice(family["split"], SPLITS), "invalid cohort or split")
    require(choice(family["audioKind"], AUDIO_KINDS) and type(family["critical"]) is bool, "invalid audio contract")
    segments = family["segments"]
    require(type(segments) is list and len(segments) <= 8, "invalid spoken segment inventory")
    for segment in segments:
        exact_keys(segment, "language text", "spoken segment schema mismatch")
        require(choice(segment["language"], {"en", "es"}) and text(segment["text"]), "invalid spoken segment")
    alternatives = family["acceptedTexts"]
    require(type(alternatives) is list and 1 <= len(alternatives) <= 8
            and all(text(item, empty=True) for item in alternatives), "invalid reference alternatives")
    require(len(set(alternatives)) == len(alternatives), "duplicate reference alternative")
    if family["audioKind"] == "speech":
        require(bool(segments) and all(item.strip() for item in alternatives), "speech requires lexical references")
        require(" ".join(segment["text"] for segment in segments) in alternatives, "literal reference is missing")
    else:
        require(not segments and alternatives == [""] and family["cohort"] == "adversarial",
                "non-speech must retain empty ground truth")
    languages = {segment["language"] for segment in segments}
    if family["cohort"] in {"en", "es"}:
        require(languages == {family["cohort"]}, "monolingual cohort language mismatch")
    elif family["cohort"] == "mixed":
        require(languages == {"en", "es"}, "mixed cohort needs both languages")


def validate_profile(profile):
    exact_keys(profile, "id gainDB noiseDB wordsPerMinute tailMilliseconds backgroundMilliseconds",
               "profile schema mismatch")
    require(identifier(profile["id"]) and integer(profile["gainDB"], -40, 0), "invalid profile identity or gain")
    require(profile["noiseDB"] is None or integer(profile["noiseDB"], -60, -12), "invalid noise floor")
    require(integer(profile["wordsPerMinute"], 80, 260)
            and integer(profile["tailMilliseconds"], 0, 2_000)
            and integer(profile["backgroundMilliseconds"], 500, 5_000), "invalid profile timing")


def validate_corpus(document):
    exact_keys(document, "schemaVersion kind generation source textLicense families profiles", "corpus schema mismatch")
    require(type(document["schemaVersion"]) is int and document["schemaVersion"] == 1
            and document["kind"] == "dictation-corpus"
            and document["generation"] == "public-synthetic-v1"
            and document["source"] == "portavoz-original-synthetic"
            and document["textLicense"] == "MIT", "unsupported corpus provenance")
    families, profiles = document["families"], document["profiles"]
    require(type(families) is list and len(families) == 60
            and type(profiles) is list and len(profiles) == 8, "corpus inventory mismatch")
    for family in families:
        validate_family(family)
    for profile in profiles:
        validate_profile(profile)
    require(len({family["id"] for family in families}) == len(families), "duplicate family identity")
    require(len({profile["id"] for profile in profiles}) == len(profiles), "duplicate profile identity")
    parameter_sets = {tuple(value for key, value in sorted(profile.items()) if key != "id") for profile in profiles}
    require(len(parameter_sets) == len(profiles), "duplicate profile parameters")
    require(Counter(family["cohort"] for family in families) == GROUP_COUNTS, "cohort coverage mismatch")
    groups = {}
    references = {}
    for family in families:
        previous = groups.setdefault(family["group"], family["split"])
        require(previous == family["split"], "related phrase families cross the split")
        for reference in family["acceptedTexts"]:
            if reference:
                # Whitespace/case cannot disguise exact duplicate references across splits.
                key = " ".join(unicodedata.normalize("NFC", reference).casefold().split())
                previous = references.setdefault(key, family["split"])
                require(previous == family["split"], "reference leaks across the split")
    for cohort in GROUP_COUNTS:
        require({family["split"] for family in families if family["cohort"] == cohort} == SPLITS,
                "a cohort lacks tuning or holdout families")
    return {f'{family["id"]}.{profile["id"]}': (family, profile) for family in families for profile in profiles}


def read_public_corpus(path=CORPUS):
    document, checksum = read_json(path)
    cells = validate_corpus(document)
    require(checksum == CORPUS_SHA256, "corpus is not the reviewed public generation")
    return document, cells


def inventory(document):
    return {
        "schemaVersion": 1, "kind": "dictation-corpus-inventory", "corpusSHA256": CORPUS_SHA256,
        "familyCounts": dict(Counter(family["cohort"] for family in document["families"])),
        "cellCounts": {key: value * len(document["profiles"]) for key, value in GROUP_COUNTS.items()},
        "phraseGroupCount": len({family["group"] for family in document["families"]}),
        "profileCount": len(document["profiles"]),
        "audioChecked": False, "qualityMeasured": False, "verifiedDeliveryMeasured": False,
    }


def validate_voices(voices):
    exact_keys(voices, "tuning holdout", "voice split schema mismatch")
    for group in voices.values():
        exact_keys(group, "en es", "voice language schema mismatch")
        require(all(digest(value) for value in group.values()), "invalid voice identity digest")
    require(set(voices["tuning"].values()).isdisjoint(voices["holdout"].values()),
            "synthetic voice leaks across the split")


def validate_audio_entry(entry, cell, voices):
    exact_keys(entry, "caseID audioSHA256 frames sampleRate channels sampleWidth voiceSHA256", "audio entry schema mismatch")
    require(digest(entry["audioSHA256"]) and integer(entry["frames"], 1, 1_920_000), "invalid PCM identity or duration")
    require(type(entry["sampleRate"]) is int and entry["sampleRate"] == 16_000
            and type(entry["channels"]) is int and entry["channels"] == 1
            and type(entry["sampleWidth"]) is int and entry["sampleWidth"] == 2, "audio must be mono 16 kHz PCM16")
    family, _ = cell
    expected = sorted({voices[family["split"]][segment["language"]] for segment in family["segments"]})
    require(entry["voiceSHA256"] == expected, "audio voice attribution mismatch")


def inspect_audio(path, expected=None, *, on_pcm=None):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            before = os.fstat(stream.fileno())
            require(stat.S_ISREG(before.st_mode) and 44 <= before.st_size <= MAX_AUDIO_BYTES, "invalid audio file bounds")
            checksum = hashlib.sha256()
            byte_count = 0
            while chunk := stream.read(64 * 1024):
                byte_count += len(chunk)
                require(byte_count <= before.st_size, "audio grew during admission")
                checksum.update(chunk)
            require(byte_count == before.st_size, "audio shrank during admission")
            actual_digest = checksum.hexdigest()
            if expected is not None:
                require(actual_digest == expected["audioSHA256"], "audio checksum mismatch")
            stream.seek(0)
            with wave.open(stream, "rb") as audio:
                declared_frames = audio.getnframes()
                require(audio.getparams()[:3] == (1, 2, 16_000) and audio.getcomptype() == "NONE"
                        and integer(declared_frames, 1, 1_920_000), "unsupported PCM header")
                if expected is not None:
                    require(declared_frames == expected["frames"], "PCM header differs from manifest")
                # RIFF headers can claim frames whose bytes never arrived.
                frames = 0
                while data := audio.readframes(16_000):
                    require(len(data) % 2 == 0, "truncated PCM sample")
                    frames += len(data) // 2
                    if on_pcm is not None:
                        on_pcm(data)
                require(frames == declared_frames, "truncated PCM payload")
            after = os.fstat(stream.fileno())
            require((before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns),
                    "audio changed during admission")
            return dict(audioSHA256=actual_digest, frames=frames, sampleRate=16_000, channels=1, sampleWidth=2)
    except (OSError, EOFError, wave.Error, RuntimeError) as error:
        # wave's RIFF chunk seeker raises RuntimeError for a chunk extending
        # beyond its container; that is malformed input, not a CLI traceback.
        raise CorpusError("audio is unreadable or malformed") from error


def validate_audio_manifest(manifest, cells, audio_root):
    exact_keys(manifest, "schemaVersion kind corpusSHA256 recipeSHA256 voices entries", "audio manifest schema mismatch")
    require(type(manifest["schemaVersion"]) is int and manifest["schemaVersion"] == 1
            and manifest["kind"] == "dictation-audio-manifest"
            and manifest["corpusSHA256"] == CORPUS_SHA256
            and digest(manifest["recipeSHA256"]), "invalid audio manifest provenance")
    validate_voices(manifest["voices"])
    entries = manifest["entries"]
    require(type(entries) is list and len(entries) == len(cells), "audio case inventory mismatch")
    indexed = {}
    checksums = {}
    for entry in entries:
        require(type(entry) is dict and type(entry.get("caseID")) is str and entry["caseID"] in cells,
                "audio case is not in the public corpus")
        case_id = entry["caseID"]
        require(case_id not in indexed, "duplicate audio case")
        validate_audio_entry(entry, cells[case_id], manifest["voices"])
        indexed[case_id] = entry
        family_id = cells[case_id][0]["id"]
        previous = checksums.setdefault(entry["audioSHA256"], family_id)
        require(previous == family_id, "unrelated families reuse the same audio")
    require(set(indexed) == set(cells), "audio case inventory mismatch")
    # Never accept a caller-supplied relative path from the manifest.
    root = Path(audio_root).resolve(strict=True)
    for case_id, entry in indexed.items():
        inspect_audio(root / (case_id + ".wav"), entry)
    return {"audioChecked": True, "audioCellCount": len(indexed),
            "distinctAudioCount": len(checksums), "syntheticVoiceCount": len({
                value for group in manifest["voices"].values() for value in group.values()})}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("verify-public", "validate-audio"))
    parser.add_argument("--corpus", type=Path, default=CORPUS)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--audio-root", type=Path)
    arguments = parser.parse_args(argv)
    try:
        document, cells = read_public_corpus(arguments.corpus)
        result = inventory(document)
        if arguments.command == "validate-audio":
            require(arguments.manifest is not None and arguments.audio_root is not None,
                    "audio validation needs a manifest and explicit audio root")
            manifest, _ = read_json(arguments.manifest)
            result.update(validate_audio_manifest(manifest, cells, arguments.audio_root))
        else:
            require(arguments.manifest is None and arguments.audio_root is None,
                    "verify-public does not consume audio")
        print(json.dumps(result, sort_keys=True, allow_nan=False))
        return 0
    except (CorpusError, OSError) as error:
        message = str(error) if isinstance(error, CorpusError) else "corpus input is unavailable"
        print("dictation corpus: " + message, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
