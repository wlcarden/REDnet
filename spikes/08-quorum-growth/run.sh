#!/usr/bin/env bash
# Spike 08 — quorum growth re-share. Pure crypto; uv pulls the vetted libs.
set -uo pipefail
cd "$(dirname "$0")"
echo "Spike 08 — quorum growth (2-of-3 -> 3-of-5 via re-share): does M/N scale with the community?"
uv run --quiet --with pycryptodome --with cryptography python3 spike.py
