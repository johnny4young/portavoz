#!/usr/bin/env python3
"""M1 acceptance check: cumulative clock drift between capture channels.

Usage:
    python3 scripts/verify_drift.py microphone.wav system.wav [--threshold-ms 50]

Method (no dependencies, stdlib only):
    Both channels contain the same real-world audio when music/speech plays
    through the speakers (the mic hears it through the air, the tap gets it
    digitally). We cross-correlate RMS envelopes of a window near the START
    of both files and a window near the END:

        lag_start  = mic-vs-system offset at the beginning
        lag_end    = mic-vs-system offset at the end
        drift      = |lag_end - lag_start|

    Constant offsets (source start order, output latency, acoustic flight
    time) appear in both lags and cancel out; what remains is cumulative
    clock divergence — the thing that must stay < 50 ms over 30 minutes for
    channel alignment to hold.

Test protocol:
    1. Play APERIODIC audio continuously — a podcast or talk radio is ideal.
       (Beat-heavy music can alias the correlation: peaks repeat every beat
       period, so short windows may lock onto the wrong beat.)
    2. swift run portavoz-cli record --seconds 1800 --system --out ~/Desktop
    3. python3 scripts/verify_drift.py ~/Desktop/microphone.wav ~/Desktop/system.wav

Validated against synthetic ground truth (60s, 1s start offset, 500 ppm
stretch): offset measured within 1 ms, drift within 3 ms.
"""

import struct
import subprocess
import sys
import tempfile
import wave

COARSE_HOP_MS = 5
FINE_HOP_MS = 1
# ScreenCaptureKit takes ~2.4s to deliver its first system-audio buffer, so
# the mic file legitimately leads by that much; the search range must cover
# it or the correlation locks onto a spurious in-range peak.
MAX_LAG_MS = 5000
FINE_SPAN_MS = 15


def read_mono_wav(path):
    # Capture writes CAF since jul 2026 (crash-safe container); the stdlib
    # wave module only reads WAV, so convert with the macOS-bundled afconvert.
    if path.endswith(".caf"):
        converted = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
        subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", "LEI16", path, converted],
            check=True, capture_output=True)
        path = converted
    with wave.open(path) as w:
        rate = w.getframerate()
        channels = w.getnchannels()
        width = w.getsampwidth()
        if width != 2:
            sys.exit(f"{path}: expected 16-bit PCM, got {width * 8}-bit")
        raw = w.readframes(w.getnframes())
    samples = struct.unpack(f"<{len(raw) // 2}h", raw)
    if channels > 1:
        samples = samples[::channels]
    return rate, samples


def envelope(samples, rate, hop_ms, start_s, length_s):
    hop = int(rate * hop_ms / 1000)
    begin = int(start_s * rate)
    end = min(begin + int(length_s * rate), len(samples))
    out = []
    for i in range(begin, end - hop, hop):
        acc = 0
        for j in range(i, i + hop):
            value = samples[j]
            acc += value if value >= 0 else -value
        out.append(acc / hop)
    mean = sum(out) / len(out) if out else 0.0
    return [value - mean for value in out]


def best_lag_ms(mic, mic_rate, system, system_rate, window_start_s, window_s, hop_ms, center_ms, span_ms):
    """Slides a mic window against a wider system region; returns lag in ms
    (positive = system is behind the mic)."""
    lag_min = center_ms - span_ms
    lag_max = center_ms + span_ms
    region_start_s = window_start_s + lag_min / 1000
    region_len_s = window_s + (lag_max - lag_min) / 1000

    a = envelope(mic, mic_rate, hop_ms, window_start_s, window_s)
    b = envelope(system, system_rate, hop_ms, region_start_s, region_len_s)
    lags = len(b) - len(a)
    if not a or lags < 1:
        sys.exit("window falls outside one of the files — recording too short?")

    best_score, best_index = None, 0
    for offset in range(lags):
        score = 0.0
        for i, value in enumerate(a):
            score += value * b[offset + i]
        if best_score is None or score > best_score:
            best_score, best_index = score, offset
    return lag_min + best_index * hop_ms


def measure_lag(mic, mic_rate, system, system_rate, window_start_s, window_s):
    coarse = best_lag_ms(
        mic, mic_rate, system, system_rate,
        window_start_s, window_s, COARSE_HOP_MS, 0, MAX_LAG_MS,
    )
    if abs(coarse) >= MAX_LAG_MS - COARSE_HOP_MS:
        print(
            f"warning: lag at t={window_start_s:.0f}s hit the ±{MAX_LAG_MS} ms "
            "search edge — the real offset is likely outside the range and the "
            "drift figure is unreliable; raise MAX_LAG_MS",
            file=sys.stderr,
        )
    return best_lag_ms(
        mic, mic_rate, system, system_rate,
        window_start_s, window_s, FINE_HOP_MS, coarse, FINE_SPAN_MS,
    )


def main():
    args = []
    threshold = 50.0
    tokens = sys.argv[1:]
    i = 0
    while i < len(tokens):
        if tokens[i] == "--threshold-ms" and i + 1 < len(tokens):
            threshold = float(tokens[i + 1])
            i += 2
        else:
            args.append(tokens[i])
            i += 1
    if len(args) != 2:
        sys.exit(__doc__)

    mic_rate, mic = read_mono_wav(args[0])
    system_rate, system = read_mono_wav(args[1])
    duration = min(len(mic) / mic_rate, len(system) / system_rate)

    margin = min(5.0, duration / 10)
    window = min(20.0, duration / 3)
    if duration < 6:
        sys.exit(f"recording too short to measure ({duration:.1f}s); need at least ~6s")

    lag_start = measure_lag(mic, mic_rate, system, system_rate, margin, window)
    lag_end = measure_lag(
        mic, mic_rate, system, system_rate,
        duration - margin - window, window,
    )
    drift = abs(lag_end - lag_start)

    print(f"duration analyzed : {duration:.1f}s")
    print(f"lag at start      : {lag_start:+.0f} ms  (constant offset: start order + latency + acoustics)")
    print(f"lag at end        : {lag_end:+.0f} ms")
    print(f"cumulative drift  : {drift:.0f} ms")
    if duration < 600:
        print("note: short recording — the acceptance criterion applies to 30 min (1800s)")
    if window < 15:
        print(f"warning: {window:.1f}s windows can alias on repetitive music — use a longer recording or a podcast")
    print("PASS" if drift < threshold else "FAIL", f"(threshold {threshold:.0f} ms)")
    sys.exit(0 if drift < threshold else 1)


if __name__ == "__main__":
    main()
