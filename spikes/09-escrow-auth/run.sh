#!/usr/bin/env bash
# Spike 09 — escrow-record authentication. Pure crypto; uv pulls the vetted libs.
set -euo pipefail
cd "$(dirname "$0")"
uv run --with cryptography --with pycryptodome python3 spike.py
