#!/usr/bin/env python3
"""Admit one person's real-microphone reading of the public speech families."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

import dictation_corpus as corpus
from materialize_dictation_corpus import publish_json

KIND = "dictation-field-audio-manifest"
PROFILE = "field"
MICROPHONES = ("built-in", "external")


def field_cells(document):
    return {family["id"] + "." + PROFILE: family for family in document["families"]
            if family["audioKind"] == "speech"}


def build(audio_root, microphone, document=None):
    """Return the manifest and the families still unrecorded; never invents audio."""
    corpus.require(microphone in MICROPHONES, "microphone must be built-in or external")
    document = document or corpus.read_public_corpus()[0]
    root = Path(audio_root).resolve(strict=True)
    entries, missing = [], []
    for case_id in sorted(field_cells(document)):
        path = root / (case_id + ".wav")
        if not path.exists():
            missing.append(case_id.removesuffix("." + PROFILE))
            continue
        entries.append({"caseID": case_id, **corpus.inspect_audio(path)})
    manifest = {"schemaVersion": 1, "kind": KIND, "corpusSHA256": corpus.CORPUS_SHA256,
                "microphone": microphone, "entries": entries}
    return manifest, missing


def validate(manifest, audio_root, document=None):
    corpus.exact_keys(manifest, "schemaVersion kind corpusSHA256 microphone entries", "field manifest schema mismatch")
    corpus.require(manifest["schemaVersion"] == 1 and manifest["kind"] == KIND
                   and manifest["corpusSHA256"] == corpus.CORPUS_SHA256
                   and manifest["microphone"] in MICROPHONES, "invalid field manifest provenance")
    cells = field_cells(document or corpus.read_public_corpus()[0])
    entries = manifest["entries"]
    corpus.require(type(entries) is list and sorted(entry.get("caseID") for entry in entries) == sorted(cells),
                   "field recordings must cover every speech family exactly once")
    root = Path(audio_root).resolve(strict=True)
    for entry in entries:
        corpus.inspect_audio(root / (entry["caseID"] + ".wav"), entry)
    return {"fieldCellCount": len(entries), "microphone": manifest["microphone"]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "validate"))
    parser.add_argument("--audio-root", type=Path, required=True)
    parser.add_argument("--microphone", choices=MICROPHONES, default="built-in")
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "build":
            manifest, missing = build(arguments.audio_root, arguments.microphone)
            if missing:
                print(json.dumps({"missing": missing}), file=sys.stderr)
                return 2
            publish_json(arguments.audio_root / "manifest.json", manifest)
        manifest, _ = corpus.read_json(arguments.audio_root / "manifest.json")
        print(json.dumps(validate(manifest, arguments.audio_root), sort_keys=True))
        return 0
    except (OSError, corpus.CorpusError) as error:
        print(f"field corpus: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
