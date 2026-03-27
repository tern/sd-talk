#!/usr/bin/env bash
# setup.sh — Download Piper TTS binary and voice model for sd-talk

set -euo pipefail

INSTALL_DIR="$HOME/.local/share/sd-talk/piper"
MODELS_DIR="$INSTALL_DIR/models"

mkdir -p "$MODELS_DIR"

# ── Piper binary ─────────────────────────────────────────────────────────────
PIPER_ARCHIVE="piper_linux_x86_64.tar.gz"
PIPER_URL="https://github.com/rhasspy/piper/releases/download/2023.11.14-2/$PIPER_ARCHIVE"

if [ ! -f "$INSTALL_DIR/piper" ]; then
    echo "Downloading Piper binary..."
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    curl -L --progress-bar -o "$TMP/$PIPER_ARCHIVE" "$PIPER_URL"
    tar -xzf "$TMP/$PIPER_ARCHIVE" -C "$TMP"
    cp "$TMP/piper/piper" "$INSTALL_DIR/"
    # copy bundled shared libs (espeak-ng data etc.)
    cp -r "$TMP/piper/"* "$INSTALL_DIR/" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/piper"
    echo "Piper installed → $INSTALL_DIR/piper"
else
    echo "Piper already installed."
fi

# ── Voice model ───────────────────────────────────────────────────────────────
HF_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main"

echo ""
echo "Choose voice model:"
echo "  1) English — en_US-lessac-medium  [default]"
echo "  2) Chinese — zh_CN-huayan-medium"
echo "  3) Both"
read -r -p "Choice [1]: " CHOICE
CHOICE="${CHOICE:-1}"

download_model() {
    local name="$1" url_path="$2"
    local dest="$MODELS_DIR/$name"
    if [ ! -f "$dest" ]; then
        echo "Downloading $name..."
        curl -L --progress-bar -o "$dest"      "$HF_BASE/$url_path"
        curl -L --progress-bar -o "${dest}.json" "$HF_BASE/${url_path}.json"
        echo "$name done."
    else
        echo "$name already exists, skipping."
    fi
}

case "$CHOICE" in
    2)   download_model "zh_CN-huayan-medium.onnx" "zh/zh_CN/huayan/medium/zh_CN-huayan-medium.onnx" ;;
    3)
        download_model "en_US-lessac-medium.onnx" "en/en_US/lessac/medium/en_US-lessac-medium.onnx"
        download_model "zh_CN-huayan-medium.onnx" "zh/zh_CN/huayan/medium/zh_CN-huayan-medium.onnx"
        ;;
    *)   download_model "en_US-lessac-medium.onnx" "en/en_US/lessac/medium/en_US-lessac-medium.onnx" ;;
esac

# ── Config ────────────────────────────────────────────────────────────────────
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sd-talk"
if [ ! -f "$CONF_DIR/config" ]; then
    mkdir -p "$CONF_DIR"
    cp "$(dirname "$0")/config.example" "$CONF_DIR/config"
    echo ""
    echo "Config installed → $CONF_DIR/config"
    echo "Edit it to change model, language, system prompt, etc."
fi

echo ""
echo "Setup complete. Run: ./sd-talk.sh"
