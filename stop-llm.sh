#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./llm-common.sh
source "$SCRIPT_DIR/llm-common.sh"

if ! llm_is_running; then
    echo "llama-server is not running on :$LLM_PORT"
    exit 0
fi

echo "Stopping llama-server on :$LLM_PORT..."
llm_stop

for _ in $(seq 1 10); do
    sleep 1
    if ! llm_is_running; then
        echo "Stopped."
        exit 0
    fi
done

echo "Warning: llama-server still appears to be running."
exit 1
