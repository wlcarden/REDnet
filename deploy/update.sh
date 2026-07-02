#!/usr/bin/env bash
# REDnet update — pulls latest code from the repo, rebuilds only what changed.
#
# Two modes:
#   ./update.sh          Interactive: shows diff, asks confirmation, rebuilds.
#   ./update.sh --auto   Unattended: pulls and rebuilds silently. For cron/systemd timer.
#
# Controls (in rednet.env):
#   REDNET_AUTO_UPDATE=true       Auto mode pulls and rebuilds (default: false — opt in)
#   REDNET_VERIFY_SIGNATURES=true Require signed commits in auto mode (default: true)
#   REDNET_UPDATE_REMOTE=origin   Git remote to fetch from (default: origin)
#   REDNET_UPDATE_BRANCH=main     Git branch to track (default: main)
#
# Kill switch:
#   touch .update-hold             Immediately pauses ALL updates (auto AND manual).
#   rm .update-hold                Resumes.
#   Auto-created when signature verification fails.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { printf "${GREEN}[update]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[update]${NC} %s\n" "$*"; }
fail() { printf "${RED}[update]${NC} %s\n" "$*"; }

[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
# Fail safe: unattended updates are opt-in, and when enabled they require signed
# commits. A default-on 15-min auto-pull+rebuild of the CORE is an RCE vector if
# the git remote is compromised/subpoenaed (bootstrap audit F3).
: "${REDNET_AUTO_UPDATE:=false}"
: "${REDNET_VERIFY_SIGNATURES:=true}"
: "${REDNET_UPDATE_REMOTE:=origin}"
: "${REDNET_UPDATE_BRANCH:=main}"

AUTO=false
[ "${1:-}" = "--auto" ] && AUTO=true

# ── kill switch ─────────────────────────────────────────────────────────────
if [ -f .update-hold ]; then
  [ "$AUTO" = true ] && exit 0
  fail "Updates paused: .update-hold exists."
  [ -s .update-hold ] && fail "Reason: $(head -1 .update-hold)"
  echo "  Remove .update-hold to resume."
  exit 1
fi

# ── auto-update toggle ──────────────────────────────────────────────────────
if [ "$AUTO" = true ] && [ "$REDNET_AUTO_UPDATE" != "true" ]; then
  exit 0
fi

# ── preflight ───────────────────────────────────────────────────────────────
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "Not a git repository."
  exit 1
fi

# ── fetch ───────────────────────────────────────────────────────────────────
log "Fetching ${REDNET_UPDATE_REMOTE}/${REDNET_UPDATE_BRANCH}..."
if ! git fetch "$REDNET_UPDATE_REMOTE" "$REDNET_UPDATE_BRANCH" 2>/dev/null; then
  [ "$AUTO" = true ] && exit 1
  fail "git fetch failed — check network and remote config."
  exit 1
fi

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "${REDNET_UPDATE_REMOTE}/${REDNET_UPDATE_BRANCH}")

if [ "$LOCAL" = "$REMOTE" ]; then
  [ "$AUTO" = false ] && log "Already up to date (${LOCAL:0:7})."
  exit 0
fi

COMMIT_COUNT=$(git rev-list --count "${LOCAL}..${REMOTE}")
log "${COMMIT_COUNT} new commit(s): ${LOCAL:0:7}..${REMOTE:0:7}"

# ── signature verification ──────────────────────────────────────────────────
if [ "$REDNET_VERIFY_SIGNATURES" = "true" ]; then
  log "Verifying commit signatures..."
  UNSIGNED=$(git log --format='%H %G?' "${LOCAL}..${REMOTE}" | grep -v ' G$' | head -5)
  if [ -n "$UNSIGNED" ]; then
    fail "BLOCKED: unsigned or untrusted commit(s):"
    echo "$UNSIGNED" | while read -r hash status; do
      fail "  ${hash:0:12} (status: $status)"
    done
    echo "Unsigned commits in ${REDNET_UPDATE_REMOTE}/${REDNET_UPDATE_BRANCH}" > .update-hold
    fail "Auto-updates paused (.update-hold created)."
    exit 1
  fi
  log "All commits signed and trusted."
fi

# ── show what changed ──────────────────────────────────────────────────────
echo
git log --oneline --no-decorate "${LOCAL}..${REMOTE}"
echo

CHANGED=$(git diff --name-only "${LOCAL}" "${REMOTE}")

# ── interactive confirmation ────────────────────────────────────────────────
if [ "$AUTO" = false ]; then
  printf "${BOLD}Apply these changes?${NC} [y/N] "
  read -r CONFIRM
  case "$CONFIRM" in y|Y|yes|YES) ;; *) log "Cancelled."; exit 0 ;; esac
fi

# ── pull ────────────────────────────────────────────────────────────────────
log "Pulling..."
if ! git pull --ff-only "$REDNET_UPDATE_REMOTE" "$REDNET_UPDATE_BRANCH"; then
  fail "Pull failed — local branch has diverged. Resolve manually."
  exit 1
fi
log "Updated to $(git rev-parse --short HEAD)."

# ── smart rebuild ───────────────────────────────────────────────────────────
REBUILT=""

if echo "$CHANGED" | grep -qE '^deploy/element-web/'; then
  log "Rebuilding Element Web..."
  if bash element-web/build.sh; then
    docker compose --profile web up -d element 2>/dev/null && REBUILT="${REBUILT}element "
  else
    warn "Element Web build failed — container unchanged."
  fi
fi

if echo "$CHANGED" | grep -qE '^deploy/caddy/'; then
  log "Reloading Caddy..."
  if docker compose restart caddy 2>/dev/null; then
    REBUILT="${REBUILT}caddy "
  else
    warn "Caddy restart failed — check Caddyfile syntax."
  fi
fi

if echo "$CHANGED" | grep -qE '^deploy/gov-bot/'; then
  log "Rebuilding gov-bot..."
  docker compose --profile governance build gov-bot 2>/dev/null
  docker compose --profile governance up -d gov-bot 2>/dev/null && REBUILT="${REBUILT}gov-bot "
fi

if echo "$CHANGED" | grep -qE '^deploy/draupnir/'; then
  log "Restarting Draupnir..."
  docker compose --profile moderation up -d draupnir 2>/dev/null && REBUILT="${REBUILT}draupnir "
fi

if echo "$CHANGED" | grep -qE '^deploy/monitoring/'; then
  log "Restarting monitoring..."
  docker compose --profile monitoring up -d prometheus 2>/dev/null && REBUILT="${REBUILT}prometheus "
fi

# Bootstrap scripts: log but never auto-apply (they mutate live room state)
BOOTSTRAP_CHANGED=$(echo "$CHANGED" | grep -E '^deploy/bootstrap-' || true)
if [ -n "$BOOTSTRAP_CHANGED" ]; then
  echo
  warn "Bootstrap scripts changed (room state, PLs, topics):"
  echo "$BOOTSTRAP_CHANGED" | sed 's/^deploy\//  /'
  warn "Review and run manually if needed."
fi

OTHER_CHANGED=$(echo "$CHANGED" | grep -E '^deploy/' | grep -vE '^deploy/(element-web|caddy|gov-bot|draupnir|monitoring|bootstrap-)' || true)
if [ -n "$OTHER_CHANGED" ]; then
  echo
  warn "Other deploy files changed:"
  echo "$OTHER_CHANGED" | sed 's/^deploy\//  /'
  warn "Review manually."
fi

echo
[ -n "$REBUILT" ] && log "Rebuilt/reloaded: ${REBUILT}"
[ -z "$REBUILT" ] && log "No services needed rebuild."
log "REDnet is at $(git rev-parse --short HEAD)."
