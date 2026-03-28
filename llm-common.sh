#!/usr/bin/env bash
# Shared helpers for managing llama-server inside the llama.cpp distrobox.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/sd-talk/config"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

LLM_CONTAINER="${LLM_CONTAINER:-llama.cpp}"
LLM_MODEL="${LLM_MODEL:-$HOME/llama.cpp/models/qwen2.5-7b-q4.gguf}"
LLM_PORT="${LLM_PORT:-8080}"
LLM_CTX="${LLM_CTX:-4096}"
LLM_GPU_LAYERS="${LLM_GPU_LAYERS:-99}"
LLM_BIN="${LLM_BIN:-/home/deck/llama.cpp/build/bin/llama-server}"
LLM_LOG="${LLM_LOG:-/tmp/llama-server.log}"

llm_health_url() {
    printf 'http://127.0.0.1:%s/health' "$LLM_PORT"
}

llm_is_running() {
    curl -sf "$(llm_health_url)" >/dev/null 2>&1
}

llm_stop() {
    pkill -f "$LLM_BIN.*--port $LLM_PORT" >/dev/null 2>&1 || true
}

llm_start() {
    if llm_is_running; then
        return 1
    fi

    : > "$LLM_LOG"
    nohup distrobox enter "$LLM_CONTAINER" -- bash -lc "
        export HSA_OVERRIDE_GFX_VERSION=10.3.0
        export LD_LIBRARY_PATH=/home/deck/llama.cpp/build/bin:\${LD_LIBRARY_PATH:-}
        exec '$LLM_BIN' \
            -m '$LLM_MODEL' \
            --host 0.0.0.0 \
            --port $LLM_PORT \
            -ngl $LLM_GPU_LAYERS \
            -c $LLM_CTX \
            --log-disable
    " >> "$LLM_LOG" 2>&1 &
}
