#!/bin/bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$PROJECT_DIR/server"

echo "=================================="
echo "       QuantAI FASTAPI"
echo "=================================="

if [ ! -f "$SERVER_DIR/app.py" ]; then
    echo "ERROR: server/app.py not found"
    exit 1
fi

if [ -f "$PROJECT_DIR/.venv/bin/activate" ]; then
    source "$PROJECT_DIR/.venv/bin/activate"
elif [ -f "$SERVER_DIR/.venv/bin/activate" ]; then
    source "$SERVER_DIR/.venv/bin/activate"
fi

cd "$SERVER_DIR"

echo "Installing/verifying dependencies..."
python -m pip install -r requirements.txt

echo ""
echo "Starting QuantAI..."
echo "Server: http://127.0.0.1:8080"
echo "Health: http://127.0.0.1:8080/health"
echo ""

exec python -m uvicorn app:app \
    --host 127.0.0.1 \
    --port 8080
