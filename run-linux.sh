#!/usr/bin/env bash
# Без pipefail: при запуске через `sh` (как иногда делает Steam) dash падает на set -o pipefail.
set -eu

cd "$(dirname "$0")"

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is not installed."
    echo "On Bazzite, install it with: rpm-ostree install python3"
    exit 1
fi

if [ ! -x ".venv/bin/python" ]; then
    python3 -m venv .venv
fi

.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python main.py
