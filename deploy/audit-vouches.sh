#!/usr/bin/env bash
# Audit the vouch graph for anomalies. The coercion canary from DESIGN.md §11:
# a compromised organizer minting a burst of tokens should be visible.
#
# Usage:
#   ./audit-vouches.sh                     # full report
#   ./audit-vouches.sh --canary            # anomaly check only (for cron/alerting)
#
# Checks:
#   - Burst minting: >5 tokens by one voucher in 24h
#   - High unclaimed rate: >50% of a voucher's tokens unclaimed
#   - Stale unclaimed: tokens minted >7 days ago and never confirmed
#
# Exit code 0 = clean, 1 = anomalies found (for cron alerting).
# Requires: jq, vouch.jsonl exists.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

VOUCH_FILE="vouch.jsonl"
[ -f "$VOUCH_FILE" ] || { echo "ERR: $VOUCH_FILE not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERR: jq required" >&2; exit 1; }

CANARY_ONLY=false
[ "${1:-}" = "--canary" ] && CANARY_ONLY=true

BURST_THRESHOLD=5
UNCLAIMED_RATE_THRESHOLD=50
STALE_DAYS=7

NOW_EPOCH=$(date +%s)
STALE_CUTOFF_EPOCH=$((NOW_EPOCH - STALE_DAYS * 86400))
DAY_AGO_EPOCH=$((NOW_EPOCH - 86400))

ANOMALIES=0

check_burst_minting(){
  echo "=== Burst minting (>$BURST_THRESHOLD tokens in 24h by one voucher) ==="
  # jq doesn't have strftime parsing, so use a simpler approach: count recent vouches per voucher
  local result
  result=$(jq -s --arg cutoff "$(date -u -d "@$DAY_AGO_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$DAY_AGO_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2000-01-01T00:00:00Z")" '
    [.[] | select(.type=="vouch" and .timestamp > $cutoff)]
    | group_by(.voucher)
    | map(select(length > '"$BURST_THRESHOLD"'))
    | map({voucher: .[0].voucher, count: length, tokens: [.[] | .label]})
    | .[]
  ' "$VOUCH_FILE" 2>/dev/null)

  if [ -n "$result" ]; then
    echo "$result" | jq -r '"  ⚠ \(.voucher): \(.count) tokens in 24h — \(.tokens | join(", "))"'
    ANOMALIES=$((ANOMALIES + 1))
  else
    echo "  clean"
  fi
  echo
}

check_unclaimed_rate(){
  echo "=== High unclaimed rate (>$UNCLAIMED_RATE_THRESHOLD% unclaimed per voucher) ==="
  local result
  result=$(jq -s '
    ([.[] | select(.type=="claimed") | .token_hash] | unique) as $claimed
    | [.[] | select(.type=="vouch")]
    | group_by(.voucher)
    | map({
        voucher: .[0].voucher,
        minted: length,
        unclaimed: [.[] | select(.token_hash as $h | $claimed | index($h) | not)] | length
      })
    | map(select(.minted > 2))
    | map(. + {rate: ((.unclaimed / .minted * 100) | round)})
    | map(select(.rate > '"$UNCLAIMED_RATE_THRESHOLD"'))
    | .[]
  ' "$VOUCH_FILE" 2>/dev/null)

  if [ -n "$result" ]; then
    echo "$result" | jq -r '"  ⚠ \(.voucher): \(.unclaimed)/\(.minted) unclaimed (\(.rate)%)"'
    ANOMALIES=$((ANOMALIES + 1))
  else
    echo "  clean"
  fi
  echo
}

check_stale_unclaimed(){
  echo "=== Stale unclaimed (minted >$STALE_DAYS days ago, never confirmed) ==="
  local cutoff
  cutoff=$(date -u -d "@$STALE_CUTOFF_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$STALE_CUTOFF_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2000-01-01T00:00:00Z")
  local result
  result=$(jq -s --arg cutoff "$cutoff" '
    ([.[] | select(.type=="claimed") | .token_hash] | unique) as $claimed
    | [.[] | select(.type=="vouch" and .timestamp < $cutoff) | select(.token_hash as $h | $claimed | index($h) | not)]
    | .[]
  ' "$VOUCH_FILE" 2>/dev/null)

  if [ -n "$result" ]; then
    echo "$result" | jq -r '"  ⚠ \(.voucher) → \"\(.label)\" (minted \(.timestamp[:10]), hash \(.token_hash[:12])...)"'
    ANOMALIES=$((ANOMALIES + 1))
  else
    echo "  clean"
  fi
  echo
}

if ! $CANARY_ONLY; then
  echo "REDnet vouch audit — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  TOTAL_V=$(jq -s '[.[] | select(.type=="vouch")] | length' "$VOUCH_FILE")
  TOTAL_C=$(jq -s '[.[] | select(.type=="claimed")] | length' "$VOUCH_FILE")
  VOUCHERS=$(jq -s '[.[] | select(.type=="vouch") | .voucher] | unique | length' "$VOUCH_FILE")
  echo "Summary: $TOTAL_V minted, $TOTAL_C confirmed, $VOUCHERS distinct vouchers"
  echo
fi

check_burst_minting
check_unclaimed_rate
check_stale_unclaimed

if [ "$ANOMALIES" -gt 0 ]; then
  echo "=== RESULT: $ANOMALIES anomaly class(es) detected ==="
  exit 1
else
  if ! $CANARY_ONLY; then
    echo "=== RESULT: clean ==="
  fi
  exit 0
fi
