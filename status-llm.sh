#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./llm-common.sh
source "$SCRIPT_DIR/llm-common.sh"

if llm_is_running; then
    model_id=$(curl -sf "http://127.0.0.1:$LLM_PORT/v1/models" | jq -r '.data[0].id // "unknown"')
    pid=$(pgrep -f "$LLM_BIN.*--port $LLM_PORT" | head -n 1 || true)
    echo "llama-server is running on :$LLM_PORT"
    echo "model: $model_id"
    if [ -n "$pid" ]; then
        echo "pid: $pid"
    fi
    exit 0
fi

echo "llama-server is not running on :$LLM_PORT"
exit 1
