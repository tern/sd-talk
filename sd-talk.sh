#!/usr/bin/env bash
# sd-talk.sh — Offline voice chat: mic → whisper → llama-server → piper → speaker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCKFILE="/tmp/sd-talk.lock"
WORK_DIR="$(mktemp -d /tmp/sd-talk-XXXXXX)"

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

MIC_SOURCE="${MIC_SOURCE:-auto}"
SAMPLE_RATE="${SAMPLE_RATE:-16000}"
CONVERSATION_TURNS="${CONVERSATION_TURNS:-6}"

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
cleanup() {
    echo ""
    echo "Shutting down..."
    kill "$REC_PID" 2>/dev/null || true
    rm -rf "$WORK_DIR"
    rm -f "$LOCKFILE"
    # Ask container to stop llama-server (best-effort)
    distrobox enter "$LLM_CONTAINER" -- bash -c \
        "pkill -f 'llama-server.*$LLM_PORT' 2>/dev/null || true" 2>/dev/null || true
    echo "Bye."
}
trap cleanup EXIT INT TERM

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
[ "$MISSING" -eq 1 ] && exit 1

# ── Start llama-server ────────────────────────────────────────────────────────
start_llm_server() {
    if curl -sf "http://localhost:$LLM_PORT/health" > /dev/null 2>&1; then
        echo "llama-server already running on :$LLM_PORT"
        return
    fi

    echo "Starting llama-server ($(basename "$LLM_MODEL"))..."

    distrobox enter "$LLM_CONTAINER" -- bash -c "
        export HSA_OVERRIDE_GFX_VERSION=10.3.0
        export LD_LIBRARY_PATH=/home/deck/llama.cpp/build/bin:\$LD_LIBRARY_PATH
        nohup /home/deck/llama.cpp/build/bin/llama-server \
            -m '$LLM_MODEL' \
            --host 0.0.0.0 \
            --port $LLM_PORT \
            -ngl $LLM_GPU_LAYERS \
            -c $LLM_CTX \
            --log-disable \
            > /tmp/llama-server.log 2>&1 &
        disown
    " 2>/dev/null

    echo -n "Waiting for server"
    for _ in $(seq 1 40); do
        sleep 1
        if curl -sf "http://localhost:$LLM_PORT/health" > /dev/null 2>&1; then
            echo " ready!"
            return
        fi
        echo -n "."
    done
    echo ""
    echo "Error: llama-server did not start. Check: distrobox enter $LLM_CONTAINER -- cat /tmp/llama-server.log"
    exit 1
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
speak() {
    local text="$1"
    local out_wav="$WORK_DIR/tts-$$.wav"

    LD_LIBRARY_PATH="$(dirname "$PIPER_BIN"):${LD_LIBRARY_PATH:-}" \
    printf '%s' "$text" | "$PIPER_BIN" \
        --model "$PIPER_MODEL" \
        --output_file "$out_wav" \
        2>/dev/null

    pw-play "$out_wav" 2>/dev/null
    rm -f "$out_wav"
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
echo "  Press Enter to speak, Ctrl+C to quit."
echo ""

# Start conversation history as JSON array with system prompt
HISTORY=$(jq -cn --arg sp "$SYSTEM_PROMPT" '[{"role":"system","content":$sp}]')

while true; do
    echo ""
    read -r -p "▶ Press Enter to record..."

    # Record
    WAV="$WORK_DIR/rec-$$.wav"
    if [ "$MIC_SOURCE" = "auto" ]; then
        pw-record --format s16 --rate "$SAMPLE_RATE" --channels 1 "$WAV" &
    else
        pw-record --target "$MIC_SOURCE" --format s16 --rate "$SAMPLE_RATE" --channels 1 "$WAV" &
    fi
    REC_PID=$!

    read -r -p "● Recording... Press Enter to stop.  "
    kill "$REC_PID" 2>/dev/null || true
    wait "$REC_PID" 2>/dev/null || true
    REC_PID=""

    if [ ! -s "$WAV" ]; then
        echo "(no audio captured)"
        rm -f "$WAV"
        continue
    fi

    # STT
    TMPOUT="$WORK_DIR/stt-$$"
    echo -n "Transcribing... "
    "$WHISPER_BIN" \
        -m "$WHISPER_MODEL" \
        -l "$WHISPER_LANG" \
        -f "$WAV" \
        --no-timestamps \
        -of "$TMPOUT" \
        -otxt 2>/dev/null
    rm -f "$WAV"

    TEXT=""
    [ -f "${TMPOUT}.txt" ] && TEXT=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' "${TMPOUT}.txt")
    rm -f "${TMPOUT}.txt"

    CLEANED=$(echo "$TEXT" | tr -d '[:punct:][:space:]')
    if [ -z "$CLEANED" ] || [ "$TEXT" = "[BLANK_AUDIO]" ]; then
        echo "(no speech detected)"
        continue
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
    speak "$REPLY"
    echo "done."
done
