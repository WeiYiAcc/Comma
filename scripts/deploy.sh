#!/usr/bin/env bash
# deploy.sh — pull a built image set from GHCR and (re)start the Comma stack.
#
# Safety model:
#   * Records the image tag currently in use to a state file before changing anything.
#   * Keeps a timestamped backup of the compose files in use.
#   * Pulls, then recreates, then health-checks.
#   * On health-check failure, automatically rolls back to the previous tag.
#
# Non-interactive: safe to run over SSH with no TTY.
#
# Configuration (environment overrides):
#   COMPOSE_PROD_OWNER   GHCR namespace                (default: weiyiacc)
#   COMPOSE_PROD_TAG     image tag to deploy           (default: latest)
#   COMPOSE_DIR          directory holding compose.yaml (default: script's ../)
#   COMPOSE_PROJECT      compose project name          (default: comma)
#   HEALTH_URLS          space-separated URLs to verify (default below)
#   HEALTH_TIMEOUT       seconds to wait for health     (default: 240)
#   STATE_FILE           where the current tag is kept  (default: <COMPOSE_DIR>/.deploy-state)
#   SKIP_PULL            1 to skip `docker compose pull`
#   NO_AUTO_ROLLBACK     1 to disable automatic rollback on failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-comma}"
COMPOSE_PROD_OWNER="${COMPOSE_PROD_OWNER:-weiyiacc}"
COMPOSE_PROD_TAG="${COMPOSE_PROD_TAG:-latest}"
STATE_FILE="${STATE_FILE:-${COMPOSE_DIR}/.deploy-state}"
HEALTH_URLS="${HEALTH_URLS:-http://localhost:8091/ http://localhost:4000/ready}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-240}"
BACKUP_DIR="${COMPOSE_DIR}/.deploy-backups"
export COMPOSE_PROD_OWNER COMPOSE_PROD_TAG

COMPOSE=(docker compose -p "${COMPOSE_PROJECT}" -f compose.yaml -f compose.prod.yaml)

log() { printf '[deploy] %s\n' "$*"; }
fail() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

cd "${COMPOSE_DIR}"
[ -f compose.yaml ] || fail "compose.yaml not found in ${COMPOSE_DIR}"
[ -f compose.prod.yaml ] || fail "compose.prod.yaml not found in ${COMPOSE_DIR} (pull the fork's main)"

# ---- record previous state -------------------------------------------------
PREV_TAG=""
if [ -f "${STATE_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${STATE_FILE}"
  PREV_TAG="${CURRENT_TAG:-}"
fi
log "previous tag: ${PREV_TAG:-<none>}"
log "target   tag: ${COMPOSE_PROD_TAG} (owner ${COMPOSE_PROD_OWNER})"

mkdir -p "${BACKUP_DIR}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
cp compose.yaml "${BACKUP_DIR}/compose.yaml.${STAMP}" 2>/dev/null || true
cp compose.prod.yaml "${BACKUP_DIR}/compose.prod.yaml.${STAMP}" 2>/dev/null || true

# ---- pull ------------------------------------------------------------------
if [ "${SKIP_PULL:-0}" != "1" ]; then
  log "pulling images"
  "${COMPOSE[@]}" pull || fail "docker compose pull failed"
fi

# ---- up --------------------------------------------------------------------
log "recreating stack"
"${COMPOSE[@]}" up -d --remove-orphans || fail "docker compose up failed"

# ---- health check ----------------------------------------------------------
health_check() {
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    local ok=1
    for url in ${HEALTH_URLS}; do
      if ! curl -fsS -o /dev/null --max-time 5 "${url}"; then
        ok=0
        break
      fi
    done
    if [ "${ok}" -eq 1 ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

log "waiting for health (${HEALTH_URLS})"
if health_check; then
  log "healthy"
  printf 'CURRENT_TAG=%s\nCURRENT_OWNER=%s\nUPDATED_AT=%s\n' \
    "${COMPOSE_PROD_TAG}" "${COMPOSE_PROD_OWNER}" "${STAMP}" > "${STATE_FILE}"
  log "recorded state in ${STATE_FILE}"
  log "DONE"
  exit 0
fi

log "HEALTH CHECK FAILED for tag ${COMPOSE_PROD_TAG}"
if [ "${NO_AUTO_ROLLBACK:-0}" = "1" ] || [ -z "${PREV_TAG}" ] || [ "${PREV_TAG}" = "${COMPOSE_PROD_TAG}" ]; then
  fail "no rollback target available; stack left on tag ${COMPOSE_PROD_TAG}. Use scripts/rollback.sh with explicit COMPOSE_PROD_TAG."
fi

log "auto-rolling back to ${PREV_TAG}"
COMPOSE_PROD_TAG="${PREV_TAG}" "${BASH_SOURCE[0]}" || fail "automatic rollback also failed"
log "rolled back to ${PREV_TAG}; deploy failed"
exit 1
