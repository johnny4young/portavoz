"""Bounded deterministic PCM transformations for synthetic dictation fixtures only."""

from array import array
import hashlib
import math
import os
from pathlib import Path
import random
import sys
import wave

from dictation_corpus import CorpusError, inspect_audio, require

SAMPLE_RATE = 16_000
MAX_FRAMES = SAMPLE_RATE * 120
BLOCK_FRAMES = SAMPLE_RATE


def read_samples(path):
    samples = array("h")

    def consume(data):
        block = array("h", data)
        if sys.byteorder != "little":
            block.byteswap()
        samples.extend(block)

    inspect_audio(path, on_pcm=consume)
    return samples


def source_samples(family, profile, speech_paths):
    if family["audioKind"] == "speech":
        require(len(speech_paths) == len(family["segments"]), "speech source inventory mismatch")
        samples = array("h")
        for path in speech_paths:
            segment = read_samples(path)
            require(any(segment), "synthesis returned silence")
            require(len(samples) + len(segment) <= MAX_FRAMES, "combined speech exceeds duration bound")
            samples.extend(segment)
        return samples
    require(not speech_paths, "background fixture cannot consume speech")
    count = profile["backgroundMilliseconds"] * SAMPLE_RATE // 1_000
    randomizer = random.Random(int.from_bytes(hashlib.sha256(family["id"].encode()).digest(), "big"))
    kind = family["audioKind"]
    if kind == "silence":
        return array("h", [0]) * count
    if kind == "noise":
        return array("h", (round((randomizer.random() * 2 - 1) * 3_276) for _ in range(count)))
    if kind == "tone":
        return array("h", (round(3_276 * math.sin(2 * math.pi * 440 * index / SAMPLE_RATE))
                           for index in range(count)))
    require(kind == "impulses", "unsupported background fixture")
    return array("h", (12_000 if index % 2_000 == 0 else 0 for index in range(count)))


def render_cell(case_id, family, profile, speech_paths, destination):
    samples = source_samples(family, profile, speech_paths)
    # This is additional padding, not a VAD estimate of where speech stopped.
    tail_frames = profile["tailMilliseconds"] * SAMPLE_RATE // 1_000
    require(0 < len(samples) + tail_frames <= MAX_FRAMES, "rendered audio exceeds duration bound")
    samples.extend(array("h", [0]) * tail_frames)
    gain = 10 ** (profile["gainDB"] / 20)
    noise = 0 if profile["noiseDB"] is None else 32_767 * 10 ** (profile["noiseDB"] / 20)
    seed = int.from_bytes(hashlib.sha256(case_id.encode()).digest(), "big")
    randomizer = random.Random(seed)
    clipped_samples = 0
    try:
        with Path(destination).open("xb") as stream, wave.open(stream, "wb") as audio:
            os.fchmod(stream.fileno(), 0o600)
            audio.setparams((1, 2, SAMPLE_RATE, len(samples), "NONE", "not compressed"))
            for start in range(0, len(samples), BLOCK_FRAMES):
                source = samples[start:start + BLOCK_FRAMES]
                if noise == 0:
                    block = source if gain == 1 else array("h", (round(sample * gain) for sample in source))
                else:
                    block = array("h")
                    for sample in source:
                        value = round(sample * gain + (randomizer.random() * 2 - 1) * noise)
                        clipped_samples += int(value < -32_768 or value > 32_767)
                        block.append(max(-32_768, min(32_767, value)))
                if sys.byteorder != "little":
                    block.byteswap()
                audio.writeframesraw(block.tobytes())
    except (OSError, wave.Error) as error:
        raise CorpusError("rendered audio could not be written") from error
    return inspect_audio(destination), clipped_samples
