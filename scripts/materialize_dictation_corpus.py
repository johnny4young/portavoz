#!/usr/bin/env python3
"""Render reviewed synthetic text with already available macOS voices, without playback."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import time

import dictation_corpus as corpus
from dictation_audio import render_cell

VOICE_LINE = re.compile(r"^(.+?)\s+([a-z]{2,3}_[A-Z]{2})\s+#")
PROCESS_SECONDS = 45
RUN_SECONDS = 3_600


def fingerprint(value):
    data = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def publish_json(path, document):
    """Publish one owner-only file without replacing another writer's result."""
    data = (json.dumps(document, sort_keys=True, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    descriptor, temporary = tempfile.mkstemp(prefix=".receipt-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


class SystemSpeech:
    def __init__(self, command_runner=subprocess.run):
        corpus.require(sys.platform == "darwin", "local speech synthesis requires macOS")
        self.command_runner = command_runner
        listing = self.run(["/usr/bin/say", "-v", "?"])
        self.voices = {match[1].strip(): match[2] for line in listing.splitlines()
                       if (match := VOICE_LINE.match(line))}
        self.os_build = self.run(["/usr/bin/sw_vers", "-buildVersion"]).strip()
        self.binary_digest = hashlib.sha256(Path("/usr/bin/say").read_bytes()).hexdigest()

    def run(self, arguments, timeout=PROCESS_SECONDS):
        try:
            result = self.command_runner(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL, timeout=timeout, check=False)
        except subprocess.TimeoutExpired as error:
            raise corpus.CorpusError("local synthesis process timed out") from error
        except OSError as error:
            raise corpus.CorpusError("local synthesis process could not start") from error
        corpus.require(result.returncode == 0, "local synthesis process failed")
        try:
            return result.stdout.decode("utf-8")
        except UnicodeError as error:
            raise corpus.CorpusError("local synthesis metadata is malformed") from error

    def identity(self, voice, language):
        corpus.require(type(voice) is str and self.voices.get(voice, "").split("_")[0] == language,
                       "requested voice is not available in the declared language")
        return {"name": voice, "locale": self.voices[voice], "osBuild": self.os_build}

    def metadata(self):
        return {"kind": "macos-say", "osBuild": self.os_build, "binarySHA256": self.binary_digest}

    def synthesize(self, text, voice, rate, destination, timeout):
        source = destination.with_suffix(".txt")
        try:
            with source.open("x", encoding="utf-8") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(text)
            self.run(["/usr/bin/say", "-v", voice, "-r", str(rate), "--file-format=WAVE",
                      "--data-format=LEI16@16000", "-f", str(source), "-o", str(destination)], timeout)
            corpus.inspect_audio(destination)
        finally:
            source.unlink(missing_ok=True)


def voice_identities(names, speech):
    corpus.exact_keys(names, "tuning holdout", "voice configuration schema mismatch")
    identities = {}
    for split, group in names.items():
        corpus.exact_keys(group, "en es", "voice language configuration mismatch")
        identities[split] = {language: speech.identity(name, language) for language, name in group.items()}
    hashes = {split: {language: fingerprint(identity) for language, identity in group.items()}
              for split, group in identities.items()}
    corpus.validate_voices(hashes)
    return identities, hashes


def processor_digest():
    sources = [Path(__file__), Path(__file__).with_name("dictation_audio.py"),
               Path(__file__).with_name("dictation_corpus.py")]
    return fingerprint({path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sources})


def materialize(output, names, speech, *, clock=time.monotonic):
    document, cells = corpus.read_public_corpus()
    identities, hashes = voice_identities(names, speech)
    recipe = {
        "schemaVersion": 1, "kind": "dictation-audio-recipe", "corpusSHA256": corpus.CORPUS_SHA256,
        "producer": speech.metadata(), "voices": identities, "pythonVersion": platform.python_version(),
        "processorSHA256": processor_digest(), "sampleRate": 16_000,
        "transforms": "pcm16-fixed-gain-uniform-noise-additional-tail-v1",
    }
    manifest = {"schemaVersion": 1, "kind": "dictation-audio-manifest", "corpusSHA256": corpus.CORPUS_SHA256,
                "recipeSHA256": fingerprint(recipe), "voices": hashes, "entries": []}
    output = Path(output)
    # Reserve one new directory. Partial output remains explicitly incomplete;
    # never recursively clean a caller's pre-existing directory or retry in it.
    output.mkdir(mode=0o700)
    deadline = clock() + RUN_SECONDS
    clipped_samples = 0
    cache_hits = 0
    synthesis_count = 0
    try:
        publish_json(output / "recipe.json", recipe)
        with tempfile.TemporaryDirectory(prefix=".speech-", dir=output) as temporary:
            cache_root = Path(temporary)
            cache = {}
            for case_id, (family, profile) in cells.items():
                corpus.require(clock() < deadline, "corpus materialization deadline exceeded")
                sources = []
                for segment in family["segments"]:
                    voice = names[family["split"]][segment["language"]]
                    key = fingerprint([hashes[family["split"]][segment["language"]],
                                       segment["text"], profile["wordsPerMinute"]])
                    if key in cache:
                        cache_hits += 1
                    else:
                        remaining = deadline - clock()
                        corpus.require(remaining > 0, "corpus materialization deadline exceeded")
                        path = cache_root / (key + ".wav")
                        speech.synthesize(segment["text"], voice, profile["wordsPerMinute"], path,
                                          min(PROCESS_SECONDS, remaining))
                        cache[key] = path
                        synthesis_count += 1
                    sources.append(cache[key])
                info, clipped = render_cell(case_id, family, profile, sources, output / (case_id + ".wav"))
                clipped_samples += clipped
                manifest["entries"].append({"caseID": case_id, **info, "voiceSHA256": sorted({
                    hashes[family["split"]][segment["language"]] for segment in family["segments"]})})
        corpus.require(clock() < deadline, "corpus materialization deadline exceeded")
        checked = corpus.validate_audio_manifest(manifest, cells, output)
        corpus.require(clock() < deadline, "corpus materialization deadline exceeded")
        receipt = {**corpus.inventory(document), **checked, "recipeSHA256": fingerprint(recipe),
                   "producerKind": speech.metadata()["kind"], "synthesisCount": synthesis_count,
                   "cacheHitCount": cache_hits, "clippedSampleCount": clipped_samples,
                   "materializationSeconds": clock() - (deadline - RUN_SECONDS)}
        publish_json(output / "materialization.json", receipt)
        # Consumers admit this only after every file and the producer receipt exist.
        publish_json(output / "manifest.json", manifest)
        return receipt
    except BaseException:
        try:
            publish_json(output / "incomplete.json", {
                "schemaVersion": 1, "kind": "dictation-materialization-incomplete",
                "completedCells": len(manifest["entries"]), "expectedCells": len(cells),
                "qualityMeasured": False, "verifiedDeliveryMeasured": False,
            })
        except OSError:
            pass
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--voices", type=Path, required=True, help="Explicit tuning/holdout EN/ES voice-name JSON")
    parser.add_argument("--output", type=Path, required=True, help="New local directory; never overwritten")
    arguments = parser.parse_args(argv)
    previous_umask = os.umask(0o077)
    try:
        names, _ = corpus.read_json(arguments.voices)
        result = materialize(arguments.output, names, SystemSpeech())
        print(json.dumps(result, sort_keys=True, allow_nan=False))
        return 0
    except (corpus.CorpusError, OSError) as error:
        message = str(error) if isinstance(error, corpus.CorpusError) else "materialization input/output is unavailable"
        print("dictation materialization: " + message, file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("dictation materialization cancelled", file=sys.stderr)
        return 130
    finally:
        os.umask(previous_umask)


if __name__ == "__main__":
    raise SystemExit(main())
