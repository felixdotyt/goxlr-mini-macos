"""Loopback latency and transparency check for a refaudio recording.

Usage: python3 -I analyze.py <recording-without-extension>

For every input channel that refaudio found a single tone on, regenerates
that output channel's stimulus exactly as refaudio.swift does, finds the
loop latency by least squares over the fade-in, and reports the residual
after alignment. A maximum difference of at most one 24-bit LSB means the
path returned the samples unchanged.

Latency is on the CoreAudio device timeline: the input sample time of the
captured frame minus the output sample time of the frame that was sent. It
excludes the device latency and safety offset CoreAudio reports separately.
"""

import json
import sys

import numpy as np

LSB24 = 2.0**-23


def load_wav(path):
    raw = open(path, "rb").read()
    channels = int.from_bytes(raw[22:24], "little")
    data = raw.index(b"data") + 8
    return np.frombuffer(raw[data:], dtype="<f4").reshape(-1, channels).astype(np.float64)


def stimulus(hz, report, frames):
    rate = report["sample_rate"]
    amplitude = 10 ** (report["level_dBFS"] / 20)
    start, end = int(report["pre_roll_s"] * rate), int((report["pre_roll_s"] + report["tone_s"]) * rate)
    fade = int(0.02 * rate)
    i = np.arange(frames)
    gain = np.where((i >= start) & (i < end), amplitude * np.minimum(1, np.minimum((i - start) / fade, (end - i) / fade)), 0.0)
    # refaudio writes Float32; Apple's driver then sends 24-bit integers.
    signal = (gain * np.sin(2 * np.pi * hz * (i - start) / rate)).astype(np.float32).astype(np.float64)
    return np.round(signal / LSB24) * LSB24, start, end


def main(base):
    report = json.load(open(base + ".json"))
    audio = load_wav(base + ".wav")
    frames = audio.shape[0]
    offset = int(report["input_minus_output_first_sample_time"])
    hz_by_output = {s["output"]: s["hz"] for s in report["stimulus"]}
    results = []
    for row in report["inputs"]:
        if len(row["tones"]) != 1:
            continue
        out = row["tones"][0]["output"]
        stim, start, end = stimulus(hz_by_output[out], report, frames)
        captured = audio[:, row["input"] - 1]
        # captured[i] should equal stim[i + offset - latency]
        window = np.arange(start - offset - 200, start - offset + 2500)
        best = None
        for latency in range(-3000, 3000):
            j = window + offset - latency
            if j.min() < 0 or j.max() >= frames:
                continue
            err = float(np.sum((captured[window] - stim[j]) ** 2))
            if best is None or err < best[1]:
                best = (latency, err)
        latency = best[0]
        i = np.arange(max(0, latency - offset), min(frames, frames + latency - offset))
        diff = captured[i] - stim[i + offset - latency]
        tone = (i + offset - latency >= start) & (i + offset - latency < end)
        max_lsb = float(np.max(np.abs(diff)) / LSB24)
        rms = float(np.sqrt(np.mean(diff[tone] ** 2)))
        results.append({
            "input": row["input"], "name": row["name"], "output": out, "latency_frames": latency,
            "residual_rms_dBFS": round(20 * np.log10(rms), 1) if rms > 0 else None,
            "max_abs_diff_lsb24": round(max_lsb, 3), "bit_exact": max_lsb <= 1.0,
        })
        print(f"in {row['input']:2d} {row['name']:<24} <- out {out:2d}  latency {latency:5d} fr  "
              f"residual {results[-1]['residual_rms_dBFS']} dBFS  max diff {max_lsb:.3f} LSB24  "
              f"{'bit-exact' if max_lsb <= 1.0 else 'not bit-exact'}")
    json.dump(results, open(base + ".analysis.json", "w"), indent=1)


if __name__ == "__main__":
    main(sys.argv[1])
