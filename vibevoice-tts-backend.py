#!/usr/bin/env python3

import argparse
import sys


def build_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument("--text", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--model")
    return parser


def main():
    args = build_parser().parse_args()
    print(
        "VibeVoice backend is not wired yet. "
        "Set TTS_BACKEND=piper to keep using Piper, or implement this backend script "
        "to render audio into: " + args.output,
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
