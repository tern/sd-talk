#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./llm-common.sh
source "$SCRIPT_DIR/llm-common.sh"

if llm_is_running; then
    echo "llama-server already running on :$LLM_PORT"
    exit 0
fi

echo "Starting llama-server ($(basename "$LLM_MODEL"))..."
llm_start

echo -n "Waiting for server"
for _ in $(seq 1 40); do
    sleep 1
    if llm_is_running; then
        echo " ready!"
        exit 0
    fi
    echo -n "."
done

echo ""
echo "Error: llama-server did not start. Check: cat $LLM_LOG"
exit 1
