#!/usr/bin/env bash
# Spike 05 — recovery-escrow crypto. Pure crypto (no Matrix server needed); uv pulls the vetted libs.
set -uo pipefail
cd "$(dirname "$0")"
echo "Spike 05 — recovery-escrow: moderators-only vs passphrase + M-of-N, plus revocation"
uv run --quiet --with pycryptodome --with pynacl python3 spike.py
