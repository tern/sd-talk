#!/usr/bin/env bash
# sd-talk.sh — Offline voice chat: mic → whisper → llama-server → piper → speaker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(mktemp -d /tmp/sd-talk-XXXXXX)"
KEEP_LLM=0
LLM_STARTED_BY_SCRIPT=0
AUTO_MODE=0
ONCE_MODE=0
PENDING_WAV=""
LAST_TRANSCRIPT=""
WAKE_ARMED=0

usage() {
    cat <<'EOF'
Usage: ./sd-talk.sh [--keep-llm] [--auto] [--once]

  --keep-llm   Leave llama-server running when sd-talk exits
  --auto       Start recording automatically when speech is detected
  --once       Record one auto utterance, answer once, then exit
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --keep-llm)
            KEEP_LLM=1
            shift
            ;;
        --auto)
            AUTO_MODE=1
            shift
            ;;
        --once)
            ONCE_MODE=1
            AUTO_MODE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

LOCKFILE_SUFFIX=""
if [ "$ONCE_MODE" -eq 1 ]; then
    LOCKFILE_SUFFIX="-once"
fi
LOCKFILE="/tmp/sd-talk${LOCKFILE_SUFFIX}.lock"

# ── Config ────────────────────────────────────────────────────────────────────
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/sd-talk/config"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "Warning: no config at $CONFIG_FILE, using defaults (run setup.sh first)"
fi

WHISPER_BIN="${WHISPER_BIN:-$HOME/bin/whisper-cpp}"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.local/share/whisper/ggml-base.bin}"
WHISPER_LANG="${WHISPER_LANG:-auto}"

LLM_CONTAINER="${LLM_CONTAINER:-llama.cpp}"
LLM_MODEL="${LLM_MODEL:-$HOME/llama.cpp/models/qwen2.5-7b-q4.gguf}"
LLM_PORT="${LLM_PORT:-8080}"
LLM_CTX="${LLM_CTX:-4096}"
LLM_GPU_LAYERS="${LLM_GPU_LAYERS:-99}"
SYSTEM_PROMPT="${SYSTEM_PROMPT:-You are a helpful voice assistant. Keep responses concise, 2-3 sentences max.}"

PIPER_BIN="${PIPER_BIN:-$HOME/.local/share/sd-talk/piper/piper}"
PIPER_MODEL="${PIPER_MODEL:-$HOME/.local/share/sd-talk/piper/models/en_US-lessac-medium.onnx}"
AUTO_RECORD_PYTHON="${AUTO_RECORD_PYTHON:-$SCRIPT_DIR/.venv/bin/python}"

MIC_SOURCE="${MIC_SOURCE:-auto}"
SAMPLE_RATE="${SAMPLE_RATE:-16000}"
CONVERSATION_TURNS="${CONVERSATION_TURNS:-6}"
WAKE_WORD="${WAKE_WORD:-}"
WAKE_ARM_SECONDS="${WAKE_ARM_SECONDS:-8}"
TTS_LEAD_IN_MS="${TTS_LEAD_IN_MS:-300}"
VAD_MODE="${VAD_MODE:-2}"
VAD_START_FRAMES="${VAD_START_FRAMES:-4}"
VAD_SILENCE_FRAMES="${VAD_SILENCE_FRAMES:-12}"
VAD_MAX_SECONDS="${VAD_MAX_SECONDS:-15}"
VAD_PRE_ROLL_FRAMES="${VAD_PRE_ROLL_FRAMES:-10}"
INTERRUPT_TTS="${INTERRUPT_TTS:-1}"
INTERRUPT_VAD_MODE="${INTERRUPT_VAD_MODE:-3}"
INTERRUPT_START_FRAMES="${INTERRUPT_START_FRAMES:-3}"
INTERRUPT_SILENCE_FRAMES="${INTERRUPT_SILENCE_FRAMES:-10}"
INTERRUPT_MAX_SECONDS="${INTERRUPT_MAX_SECONDS:-2.5}"
INTERRUPT_PRE_ROLL_FRAMES="${INTERRUPT_PRE_ROLL_FRAMES:-6}"

# shellcheck source=./llm-common.sh
source "$SCRIPT_DIR/llm-common.sh"

# ── Lockfile ──────────────────────────────────────────────────────────────────
if [ -f "$LOCKFILE" ]; then
    OLD_PID=$(cat "$LOCKFILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Error: sd-talk already running (PID $OLD_PID). Use Ctrl+C to stop it first."
        exit 1
    fi
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"

# ── Cleanup ───────────────────────────────────────────────────────────────────
REC_PID=""
AUTO_REC_PID=""
PLAY_PID=""
cleanup() {
    echo ""
    echo "Shutting down..."
    kill "$REC_PID" 2>/dev/null || true
    kill "$AUTO_REC_PID" 2>/dev/null || true
    kill "$PLAY_PID" 2>/dev/null || true
    rm -rf "$WORK_DIR"
    rm -f "$LOCKFILE"
    if [ "$KEEP_LLM" -eq 0 ] && [ "$LLM_STARTED_BY_SCRIPT" -eq 1 ]; then
        llm_stop
    fi
    echo "Bye."
}
on_signal() {
    trap - INT TERM
    exit 130
}
trap cleanup EXIT
trap on_signal INT TERM

# ── Dependency check ──────────────────────────────────────────────────────────
MISSING=0
[ ! -f "$WHISPER_BIN" ] && { echo "Error: whisper not found at $WHISPER_BIN"; MISSING=1; }
[ ! -f "$WHISPER_MODEL" ] && { echo "Error: whisper model not found at $WHISPER_MODEL"; MISSING=1; }
[ ! -f "$PIPER_BIN" ] && { echo "Error: piper not found at $PIPER_BIN — run: $SCRIPT_DIR/setup.sh"; MISSING=1; }
[ ! -f "$PIPER_MODEL" ] && { echo "Error: piper model not found at $PIPER_MODEL — run: $SCRIPT_DIR/setup.sh"; MISSING=1; }
command -v pw-record &>/dev/null || { echo "Error: pw-record not found (PipeWire missing?)"; MISSING=1; }
command -v pw-play   &>/dev/null || { echo "Error: pw-play not found (PipeWire missing?)"; MISSING=1; }
command -v curl      &>/dev/null || { echo "Error: curl not found"; MISSING=1; }
command -v jq        &>/dev/null || { echo "Error: jq not found — install with: sudo pacman -S jq"; MISSING=1; }
command -v ffmpeg    &>/dev/null || { echo "Error: ffmpeg not found"; MISSING=1; }
[ ! -x "$AUTO_RECORD_PYTHON" ] && { echo "Error: auto-record python not found at $AUTO_RECORD_PYTHON"; MISSING=1; }
[ "$MISSING" -eq 1 ] && exit 1

# ── Start llama-server ────────────────────────────────────────────────────────
start_llm_server() {
    if llm_is_running; then
        echo "llama-server already running on :$LLM_PORT"
        return
    fi

    "$SCRIPT_DIR/start-llm.sh"
    LLM_STARTED_BY_SCRIPT=1
}

# ── Ask LLM ───────────────────────────────────────────────────────────────────
ask_llm() {
    local messages_json="$1"

    local body
    body=$(jq -cn \
        --argjson msgs "$messages_json" \
        '{messages: $msgs, temperature: 0.7, max_tokens: 200, stream: false}')

    curl -sf "http://localhost:$LLM_PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$body" \
        | jq -r '.choices[0].message.content // empty'
}

# ── Speak ─────────────────────────────────────────────────────────────────────
synthesize_tts() {
    local text="$1"
    local out_wav="$2"

    LD_LIBRARY_PATH="$(dirname "$PIPER_BIN"):${LD_LIBRARY_PATH:-}" \
    printf '%s' "$text" | "$PIPER_BIN" \
        --model "$PIPER_MODEL" \
        --output_file "$out_wav" \
        >/dev/null 2>/dev/null

    "$AUTO_RECORD_PYTHON" - "$out_wav" "$TTS_LEAD_IN_MS" <<'PY'
import sys
import wave

path = sys.argv[1]
lead_ms = int(sys.argv[2])

with wave.open(path, "rb") as src:
    params = src.getparams()
    frames = src.readframes(src.getnframes())

lead_frames = int(params.framerate * lead_ms / 1000)
silence = b"\x00" * lead_frames * params.sampwidth * params.nchannels

with wave.open(path + ".tmp", "wb") as dst:
    dst.setparams(params)
    dst.writeframes(silence + frames)

import os
os.replace(path + ".tmp", path)
PY
}

normalize_text() {
    "$AUTO_RECORD_PYTHON" - "$1" <<'PY'
import sys
text = sys.argv[1].casefold()
print("".join(ch for ch in text if ch.isalnum()))
PY
}

extract_wake_word_payload() {
    local text="$1"

    if [ -z "$WAKE_WORD" ]; then
        printf '%s\n' "$text"
        return 0
    fi

    "$AUTO_RECORD_PYTHON" - "$WAKE_WORD" "$text" <<'PY'
import sys

wake = sys.argv[1].strip()
text = sys.argv[2].strip()

def normalize(value: str) -> str:
    return "".join(ch for ch in value.casefold() if ch.isalnum())

norm_wake = normalize(wake)
norm_text = normalize(text)

if not norm_wake:
    print(text)
    raise SystemExit(0)

if norm_text == norm_wake:
    print("__WAKE_ONLY__")
    raise SystemExit(0)

prefixes = (
    wake,
    wake + "，",
    wake + ",",
    wake + "。",
    wake + ".",
    wake + " ",
    wake + "：",
    wake + ":",
)

payload = None
for prefix in prefixes:
    if text.startswith(prefix):
        payload = text[len(prefix):].strip()
        break

if payload is None and norm_text.startswith(norm_wake):
    payload = text[len(wake):].lstrip(" ，,。.:：!?！？")

if payload is None or not payload.strip():
    raise SystemExit(1)

print(payload.strip())
PY
}

record_manual() {
    local wav="$1"

    if [ "$MIC_SOURCE" = "auto" ]; then
        pw-record --format s16 --rate "$SAMPLE_RATE" --channels 1 "$wav" &
    else
        pw-record --target "$MIC_SOURCE" --format s16 --rate "$SAMPLE_RATE" --channels 1 "$wav" &
    fi
    REC_PID=$!

    read -r -p "● Recording... Press Enter to stop.  "
    kill "$REC_PID" 2>/dev/null || true
    wait "$REC_PID" 2>/dev/null || true
    REC_PID=""
}

run_auto_record() {
    local wav="$1"
    local vad_mode="$2"
    local start_frames="$3"
    local silence_frames="$4"
    local max_seconds="$5"
    local pre_roll_frames="$6"
    local rc

    "$AUTO_RECORD_PYTHON" "$SCRIPT_DIR/auto-record.py" \
        --output "$wav" \
        --source "$MIC_SOURCE" \
        --sample-rate "$SAMPLE_RATE" \
        --vad-mode "$vad_mode" \
        --start-frames "$start_frames" \
        --silence-frames "$silence_frames" \
        --max-seconds "$max_seconds" \
        --pre-roll-frames "$pre_roll_frames" &
    AUTO_REC_PID=$!
    wait "$AUTO_REC_PID"
    rc=$?
    AUTO_REC_PID=""
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 130 ] || [ "$rc" -eq 143 ]; then
            exit 130
        fi
        return 1
    fi
}

record_auto() {
    local wav="$1"

    echo "▶ Auto mode armed. Start speaking..."
    run_auto_record \
        "$wav" \
        "$VAD_MODE" \
        "$VAD_START_FRAMES" \
        "$VAD_SILENCE_FRAMES" \
        "$VAD_MAX_SECONDS" \
        "$VAD_PRE_ROLL_FRAMES"
}

play_tts_with_interrupt() {
    local tts_wav="$1"
    local interrupt_wav="$WORK_DIR/interrupt-$$.wav"

    pw-play "$tts_wav" 2>/dev/null &
    PLAY_PID=$!

    if [ "$AUTO_MODE" -eq 1 ] && [ "$INTERRUPT_TTS" -eq 1 ]; then
        while kill -0 "$PLAY_PID" 2>/dev/null; do
            rm -f "$interrupt_wav"
            if run_auto_record \
                "$interrupt_wav" \
                "$INTERRUPT_VAD_MODE" \
                "$INTERRUPT_START_FRAMES" \
                "$INTERRUPT_SILENCE_FRAMES" \
                "$INTERRUPT_MAX_SECONDS" \
                "$INTERRUPT_PRE_ROLL_FRAMES"; then
                kill "$PLAY_PID" 2>/dev/null || true
                wait "$PLAY_PID" 2>/dev/null || true
                PLAY_PID=""
                if [ -s "$interrupt_wav" ]; then
                    PENDING_WAV="$interrupt_wav"
                    return 0
                fi
            fi
        done
    fi

    wait "$PLAY_PID" 2>/dev/null || true
    PLAY_PID=""
    rm -f "$interrupt_wav"
    return 1
}

speak() {
    local text="$1"
    local out_wav="$WORK_DIR/tts-$$.wav"

    synthesize_tts "$text" "$out_wav"
    play_tts_with_interrupt "$out_wav"
    local interrupted=$?
    rm -f "$out_wav"
    return "$interrupted"
}

transcribe_wav() {
    local wav="$1"
    local tmpout="$WORK_DIR/stt-$$"
    local text cleaned

    echo -n "Transcribing... "
    "$WHISPER_BIN" \
        -m "$WHISPER_MODEL" \
        -l "$WHISPER_LANG" \
        -f "$wav" \
        --no-timestamps \
        -of "$tmpout" \
        -otxt 2>/dev/null
    rm -f "$wav"

    text=""
    [ -f "${tmpout}.txt" ] && text=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' "${tmpout}.txt")
    rm -f "${tmpout}.txt"

    cleaned=$(echo "$text" | tr -d '[:punct:][:space:]')
    if [ -z "$cleaned" ] || [ "$text" = "[BLANK_AUDIO]" ]; then
        echo "(no speech detected)"
        LAST_TRANSCRIPT=""
        return 1
    fi

    LAST_TRANSCRIPT="$text"
    return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────
start_llm_server

echo ""
echo "╔══════════════════════════════════╗"
echo "║  SD-Talk — Offline Voice Chat    ║"
echo "╠══════════════════════════════════╣"
printf "║  STT  %-27s║\n" "$(basename "$WHISPER_MODEL")"
printf "║  LLM  %-27s║\n" "$(basename "$LLM_MODEL")"
printf "║  TTS  %-27s║\n" "$(basename "$PIPER_MODEL")"
echo "╚══════════════════════════════════╝"
if [ "$AUTO_MODE" -eq 1 ]; then
    echo "  Auto mode: speak normally, Ctrl+C to quit."
    if [ -n "$WAKE_WORD" ]; then
        echo "  Wake word: $WAKE_WORD"
    fi
else
    echo "  Press Enter to speak, Ctrl+C to quit."
fi
echo ""

# Start conversation history as JSON array with system prompt
HISTORY=$(jq -cn --arg sp "$SYSTEM_PROMPT" '[{"role":"system","content":$sp}]')

while true; do
    echo ""
    if [ -n "$PENDING_WAV" ] && [ -s "$PENDING_WAV" ]; then
        WAV="$PENDING_WAV"
        PENDING_WAV=""
    else
        WAV="$WORK_DIR/rec-$$.wav"

        if [ "$AUTO_MODE" -eq 1 ]; then
            if ! record_auto "$WAV"; then
                echo "(no speech detected)"
                rm -f "$WAV"
                continue
            fi
        else
            read -r -p "▶ Press Enter to record..."
            record_manual "$WAV"
        fi
    fi

    if [ ! -s "$WAV" ]; then
        echo "(no audio captured)"
        rm -f "$WAV"
        continue
    fi

    if ! transcribe_wav "$WAV"; then
        continue
    fi

    TEXT="$LAST_TRANSCRIPT"

    if [ "$AUTO_MODE" -eq 1 ] && [ "$ONCE_MODE" -eq 0 ] && [ -n "$WAKE_WORD" ]; then
        if [ "$WAKE_ARMED" -eq 1 ]; then
            WAKE_ARMED=0
        else
            if ! TEXT=$(extract_wake_word_payload "$TEXT"); then
                echo "(wake word not detected)"
                continue
            fi
            if [ "$TEXT" = "__WAKE_ONLY__" ]; then
                WAKE_ARMED=1
                echo "(wake word detected)"
                continue
            fi
        fi
    fi

    echo "You: $TEXT"

    # Append user turn
    HISTORY=$(echo "$HISTORY" | jq --arg m "$TEXT" '. + [{"role":"user","content":$m}]')

    # Trim to CONVERSATION_TURNS (keep system prompt + last N*2 messages)
    HISTORY=$(echo "$HISTORY" | jq --argjson n "$((CONVERSATION_TURNS * 2 + 1))" \
        'if length > $n then .[0:1] + .[-($n-1):] else . end')

    # LLM
    echo -n "Thinking... "
    REPLY=$(ask_llm "$HISTORY")

    if [ -z "$REPLY" ]; then
        echo "(LLM returned empty response)"
        continue
    fi

    echo "AI: $REPLY"

    # Append assistant turn
    HISTORY=$(echo "$HISTORY" | jq --arg m "$REPLY" '. + [{"role":"assistant","content":$m}]')

    # TTS + playback
    echo -n "Speaking... "
    if speak "$REPLY"; then
        echo "interrupted."
    else
        echo "done."
    fi

    if [ "$ONCE_MODE" -eq 1 ]; then
        break
    fi
done
