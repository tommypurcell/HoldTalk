#!/bin/bash
# Downloads a Whisper speech model. Usage: download-model.sh [large-v3-turbo-q5_0|small|medium]
set -euo pipefail

name="${1:-large-v3-turbo-q5_0}"
case "$name" in
    large-v3-turbo-q5_0 | small | medium | small.en | medium.en) ;;
    *) echo "Choose large-v3-turbo-q5_0, small or medium."; exit 1 ;;
esac

folder="$HOME/.config/holdtalk/models"
mkdir -p "$folder"
target="$folder/ggml-$name.bin"
if [ -f "$target" ]; then
    echo "Already downloaded: $target"
    exit 0
fi

curl -fL --retry 3 -C - -o "$target.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$name.bin"
mv "$target.part" "$target"
echo "Saved: $target"
