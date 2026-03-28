#!/usr/bin/env python3

import argparse
import collections
import os
import signal
import subprocess
import sys
import time
import wave

import webrtcvad


stop_requested = False
child_proc = None


def terminate_child(sig=signal.SIGTERM):
    global child_proc
    if child_proc is None:
        return
    try:
        os.killpg(child_proc.pid, sig)
    except ProcessLookupError:
        pass


def handle_signal(_signum, _frame):
    global stop_requested
    stop_requested = True
    terminate_child(signal.SIGTERM)


def build_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--source", default="auto")
    parser.add_argument("--sample-rate", type=int, default=16000)
    parser.add_argument("--vad-mode", type=int, default=2)
    parser.add_argument("--start-frames", type=int, default=4)
    parser.add_argument("--silence-frames", type=int, default=12)
    parser.add_argument("--max-seconds", type=float, default=15.0)
    parser.add_argument("--pre-roll-frames", type=int, default=10)
    return parser


def resolve_source(source):
    if source != "auto":
        return source
    try:
        result = subprocess.run(
            ["pactl", "get-default-source"],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip() or "default"
    except Exception:
        return "default"


def main():
    global child_proc

    args = build_parser().parse_args()
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    source = resolve_source(args.source)
    sample_rate = args.sample_rate
    frame_ms = 30
    bytes_per_sample = 2
    channels = 1
    chunk_bytes = sample_rate * bytes_per_sample * channels * frame_ms // 1000
    vad = webrtcvad.Vad(args.vad_mode)
    pre_roll = collections.deque(maxlen=args.pre_roll_frames)
    captured = []
    speech_frames = 0
    silence_frames = 0
    started = False
    start_time = time.monotonic()

    cmd = [
        "ffmpeg",
        "-loglevel",
        "error",
        "-nostdin",
        "-f",
        "pulse",
        "-i",
        source,
        "-ac",
        "1",
        "-ar",
        str(sample_rate),
        "-f",
        "s16le",
        "-",
    ]

    child_proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        preexec_fn=os.setsid,
    )

    try:
        while True:
            if stop_requested:
                return 130
            if time.monotonic() - start_time > args.max_seconds:
                break

            chunk = child_proc.stdout.read(chunk_bytes)
            if not chunk or len(chunk) < chunk_bytes:
                break

            is_speech = vad.is_speech(chunk, sample_rate)
            pre_roll.append(chunk)

            if is_speech:
                speech_frames += 1
                silence_frames = 0
            else:
                speech_frames = 0
                if started:
                    silence_frames += 1

            if not started and speech_frames >= args.start_frames:
                started = True
                captured.extend(pre_roll)

            if started:
                captured.append(chunk)
                if silence_frames >= args.silence_frames:
                    break
    finally:
        terminate_child(signal.SIGTERM)
        try:
            child_proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            terminate_child(signal.SIGKILL)
            child_proc.wait(timeout=2)
        child_proc = None

    if not started or not captured:
        return 1

    with wave.open(args.output, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(bytes_per_sample)
        wav.setframerate(sample_rate)
        wav.writeframes(b"".join(captured))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
