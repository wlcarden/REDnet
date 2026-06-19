#!/usr/bin/env bash
# Spike 06 — moderator keys on P-256 secure elements. Pure crypto; uv pulls the vetted libs.
set -uo pipefail
cd "$(dirname "$0")"
echo "Spike 06 — P-256 ECIES moderator keys + the full escrow construction (Phase-2 foundation)"
uv run --quiet --with cryptography --with pycryptodome python3 spike.py
