#!/usr/bin/env bash
# Query the vouch provenance graph. Reads vouch.jsonl (the local index maintained
# by mint-invite.sh and confirm-vouch.sh).
#
# Usage:
#   ./vouch-tree.sh @username              # who vouched for this person?
#   ./vouch-tree.sh --voucher @organizer   # everyone this organizer vouched for
#   ./vouch-tree.sh --tree                 # full graph: all vouches + claims
#   ./vouch-tree.sh --orphans              # members with no vouch record
#   ./vouch-tree.sh --stats                # per-voucher mint counts + rate summary
#   ./vouch-tree.sh --unclaimed            # minted but not yet confirmed
#
# Requires: jq, vouch.jsonl exists (run mint-invite.sh or bootstrap-governance.sh).
set -uo pipefail
cd "$(dirname "$0")" || exit 1

VOUCH_FILE="vouch.jsonl"
[ -f "$VOUCH_FILE" ] || { echo "ERR: $VOUCH_FILE not found — run bootstrap-governance.sh first" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERR: jq required" >&2; exit 1; }

MODE=""
TARGET=""

case "${1:-}" in
  @*)          MODE="lookup"; TARGET="$1" ;;
  --voucher)   MODE="by-voucher"; TARGET="${2:?usage: $0 --voucher @organizer}"; shift ;;
  --tree)      MODE="tree" ;;
  --orphans)   MODE="orphans" ;;
  --stats)     MODE="stats" ;;
  --unclaimed) MODE="unclaimed" ;;
  *)           echo "Usage: $0 @username | --voucher @org | --tree | --orphans | --stats | --unclaimed" >&2; exit 1 ;;
esac

case "$MODE" in
  lookup)
    echo "Provenance for $TARGET:"
    echo
    FOUND=$(jq -r "select(.type==\"claimed\" and .account==\"$TARGET\") | \"  vouched by: \\(.voucher)\\n  label:      \\(.label // \"(none)\")\\n  confirmed:  \\(.confirmed_at)\"" "$VOUCH_FILE")
    if [ -n "$FOUND" ]; then
      echo "$FOUND"
    else
      echo "  No vouch record found for $TARGET."
      echo "  (They may have joined before vouch tracking was enabled.)"
    fi
    ;;

  by-voucher)
    echo "Invites minted by $TARGET:"
    echo
    echo "  MINTED (tokens issued):"
    jq -r "select(.type==\"vouch\" and .voucher==\"$TARGET\") | \"    \\(.timestamp)  \\(.label)  [\\(.token_hash[:12])...]\"" "$VOUCH_FILE" \
      | sort || echo "    (none)"
    echo
    echo "  CONFIRMED (people who arrived):"
    jq -r "select(.type==\"claimed\" and .voucher==\"$TARGET\") | \"    \\(.confirmed_at)  \\(.account)  \\(.label // \"\")\"" "$VOUCH_FILE" \
      | sort || echo "    (none)"
    ;;

  tree)
    echo "Full vouch graph:"
    echo
    TOTAL_VOUCHES=$(jq -s '[.[] | select(.type=="vouch")] | length' "$VOUCH_FILE")
    TOTAL_CLAIMS=$(jq -s '[.[] | select(.type=="claimed")] | length' "$VOUCH_FILE")
    echo "  $TOTAL_VOUCHES invites minted, $TOTAL_CLAIMS confirmed"
    echo
    echo "  VOUCHER → MEMBER (confirmed):"
    jq -r 'select(.type=="claimed") | "    \(.voucher) → \(.account)  (\(.confirmed_at[:10]))"' "$VOUCH_FILE" \
      | sort || echo "    (none yet)"
    echo
    echo "  PENDING (minted, not confirmed):"
    CLAIMED_HASHES=$(jq -r 'select(.type=="claimed") | .token_hash // empty' "$VOUCH_FILE" 2>/dev/null | sort -u)
    jq -r 'select(.type=="vouch") | "\(.token_hash)\t\(.voucher)\t\(.label)\t\(.timestamp)"' "$VOUCH_FILE" \
      | while IFS=$'\t' read -r hash voucher label ts; do
          if ! echo "$CLAIMED_HASHES" | grep -qF "${hash:0:12}" 2>/dev/null; then
            echo "    $voucher → \"$label\"  ($ts, ${hash:0:12}...)"
          fi
        done
    ;;

  stats)
    echo "Voucher statistics:"
    echo
    jq -s '
      [.[] | select(.type=="vouch")]
      | group_by(.voucher)
      | map({
          voucher: .[0].voucher,
          minted: length,
          first: (map(.timestamp) | sort | first),
          last: (map(.timestamp) | sort | last)
        })
      | sort_by(-.minted)
      | .[]
      | "  \(.voucher): \(.minted) minted  (first: \(.first[:10]), last: \(.last[:10]))"
    ' "$VOUCH_FILE" 2>/dev/null || echo "  (no vouches recorded)"
    echo
    TOTAL=$(jq -s '[.[] | select(.type=="vouch")] | length' "$VOUCH_FILE")
    CLAIMED=$(jq -s '[.[] | select(.type=="claimed")] | length' "$VOUCH_FILE")
    echo "  total: $TOTAL minted, $CLAIMED confirmed, $((TOTAL - CLAIMED)) pending"
    ;;

  unclaimed)
    echo "Unclaimed invites (minted but not confirmed):"
    echo
    jq -s '
      ([.[] | select(.type=="claimed") | .token_hash] | unique) as $claimed
      | [.[] | select(.type=="vouch") | select(.token_hash as $h | $claimed | index($h) | not)]
      | sort_by(.timestamp)
      | .[]
      | "  \(.timestamp)  \(.voucher) → \"\(.label)\"  [\(.token_hash[:12])...]"
    ' "$VOUCH_FILE" 2>/dev/null || echo "  (none)"
    ;;
esac
