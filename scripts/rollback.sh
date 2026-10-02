#!/usr/bin/env bash
# rollback.sh — return the Comma stack to a previously recorded image tag.
#
# Two modes:
#   1. No arguments: roll back to the tag recorded in the previous deploy's
#      backup (the tag that was live before the last deploy.sh run).
#   2. COMPOSE_PROD_TAG=<tag> rollback.sh [tag]: roll back to an explicit tag
#      (must still exist in the registry).
#
# Every deploy.sh run also snapshots the compose files under .deploy-backups/;
# this script can restore the newest snapshot if RESTORE_COMPOSE=1.
#
# Non-interactive: safe to run over SSH with no TTY.
#
# Configuration (environment overrides):
#   COMPOSE_PROD_OWNER   GHCR namespace            (default: weiyiacc)
#   COMPOSE_PROD_TAG     explicit tag to roll back to (default: value in backup)
#   COMPOSE_DIR          directory holding compose.yaml (default: script's ../)
#   COMPOSE_PROJECT      compose project name      (default: comma)
#   HEALTH_URLS / HEALTH_TIMEOUT   as in deploy.sh
#   RESTORE_COMPOSE      1 to restore the newest compose snapshot first
#   DRY_RUN              1 to print the plan without changing anything
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-comma}"
COMPOSE_PROD_OWNER="${COMPOSE_PROD_OWNER:-weiyiacc}"
STATE_FILE="${STATE_FILE:-${COMPOSE_DIR}/.deploy-state}"
HEALTH_URLS="${HEALTH_URLS:-http://localhost:8091/ http://localhost:4000/ready}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-240}"
BACKUP_DIR="${COMPOSE_DIR}/.deploy-backups"

export COMPOSE_PROD_OWNER
COMPOSE=(docker compose -p "${COMPOSE_PROJECT}" -f compose.yaml -f compose.prod.yaml)

log() { printf '[rollback] %s\n' "$*"; }
fail() { printf '[rollback] ERROR: %s\n' "$*" >&2; exit 1; }

cd "${COMPOSE_DIR}"

# ---- determine the target tag ---------------------------------------------
CURRENT_TAG=""
[ -f "${STATE_FILE}" ] && { . "${STATE_FILE}"; CURRENT_TAG="${CURRENT_TAG:-}"; }

TARGET_TAG="${COMPOSE_PROD_TAG:-}"
if [ -z "${TARGET_TAG}" ] && [ $# -ge 1 ]; then
  TARGET_TAG="$1"
fi
if [ -z "${TARGET_TAG}" ]; then
  TARGET_TAG="${CURRENT_TAG:-}"
fi
if [ -z "${TARGET_TAG}" ]; then
  fail "no rollback target. Pass a tag: COMPOSE_PROD_TAG=<tag> $0  (or $0 <tag>)"
fi
export COMPOSE_PROD_TAG="${TARGET_TAG}"

log "current tag: ${CURRENT_TAG:-<unknown>}"
log "target  tag: ${TARGET_TAG} (owner ${COMPOSE_PROD_OWNER})"

if [ "${RESTORE_COMPOSE:-0}" = "1" ]; then
  SNAP="$(ls -1t "${BACKUP_DIR}"/compose.prod.yaml.* 2>/dev/null | head -n1 || true)"
  if [ -n "${SNAP}" ]; then
    log "restoring compose snapshot ${SNAP}"
    cp "${SNAP}" compose.prod.yaml
  else
    log "no compose snapshot found; leaving current files"
  fi
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  log "DRY_RUN: would pull and up -d for tag ${TARGET_TAG}"
  exit 0
fi

log "pulling target images"
"${COMPOSE[@]}" pull || fail "pull failed for tag ${TARGET_TAG}"

log "recreating stack"
"${COMPOSE[@]}" up -d --remove-orphans || fail "up failed"

health_check() {
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    local ok=1
    for url in ${HEALTH_URLS}; do
      curl -fsS -o /dev/null --max-time 5 "${url}" || { ok=0; break; }
    done
    [ "${ok}" -eq 1 ] && return 0
    sleep 5
  done
  return 1
}

log "waiting for health (${HEALTH_URLS})"
if health_check; then
  log "healthy"
  printf 'CURRENT_TAG=%s\nCURRENT_OWNER=%s\nUPDATED_AT=%s\n' \
    "${TARGET_TAG}" "${COMPOSE_PROD_OWNER}" "$(date -u +%Y%m%dT%H%M%SZ)" > "${STATE_FILE}"
  log "rollback complete; state recorded in ${STATE_FILE}"
  exit 0
fi

fail "rollback target ${TARGET_TAG} is not healthy either; manual intervention needed"
