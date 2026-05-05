#!/usr/bin/env bash
# Start the mlx_lm OpenAI-compatible server.
# Model is read from ~/.netmon/config.json (mlx_model key).
# Default: mlx-community/Qwen3-4B-4bit
set -euo pipefail

NETMON="${HOME}/.netmon"
CONFIG="${NETMON}/config.json"

if command -v python3 &>/dev/null && python3 -c "import mlx_lm" 2>/dev/null; then
    PY="python3"
elif [ -x "/opt/homebrew/bin/python3" ]; then
    PY="/opt/homebrew/bin/python3"
else
    echo "python3 with mlx_lm not found" >&2
    exit 1
fi

# Read model from config (fallback to default)
if [ -f "$CONFIG" ]; then
    MODEL=$(python3 -c "import json,sys; d=json.load(open('$CONFIG')); print(d.get('mlx_model','mlx-community/Qwen3-4B-4bit'))" 2>/dev/null || echo "mlx-community/Qwen3-4B-4bit")
else
    MODEL="mlx-community/Qwen3-4B-4bit"
fi

echo "Starting mlx_lm server with model: $MODEL"
exec "$PY" -m mlx_lm server --model "$MODEL" --port 8080
