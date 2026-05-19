#!/usr/bin/env bash
# 03_load_images.sh
# Loads Docker image archives via docker load, verifies tags, and retags images when configured.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

section() { printf '\n===== %s =====\n' "$1"; }

section "Configuration"
show_config_summary

section "Docker availability"
require_cmd docker
if ! docker info >/dev/null 2>&1; then
  die "Docker daemon is unavailable for current user. Check service status or docker group membership."
fi
log "Docker daemon is available."

section "Image archives"
[[ -d "${IMAGE_ARCHIVE_DIR}" ]] || die "Image archive directory does not exist: ${IMAGE_ARCHIVE_DIR}"

mapfile -t archives < <(find "${IMAGE_ARCHIVE_DIR}" -maxdepth 1 -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' \) | sort)

if [[ "${#archives[@]}" -eq 0 ]]; then
  warn "No image archives found in ${IMAGE_ARCHIVE_DIR}. Expected *.tar, *.tar.gz, or *.tgz."
else
  for archive in "${archives[@]}"; do
    info "Loading image archive: ${archive}"
    docker load -i "${archive}"
  done
  log "Docker archives were loaded."
fi

section "Retag rules"
if [[ -n "${RETAG_RULES}" ]]; then
  for rule in ${RETAG_RULES}; do
    old_tag="${rule%%=*}"
    new_tag="${rule#*=}"
    if [[ -z "${old_tag}" || -z "${new_tag}" || "${old_tag}" == "${new_tag}" ]]; then
      warn "Skipping invalid retag rule: ${rule}"
      continue
    fi
    if docker image inspect "${old_tag}" >/dev/null 2>&1; then
      docker tag "${old_tag}" "${new_tag}"
      log "Retagged ${old_tag} -> ${new_tag}"
    else
      warn "Cannot retag missing source image: ${old_tag}"
    fi
  done
else
  info "No RETAG_RULES configured."
fi

section "Loaded image tags"
docker image ls --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}' | sed -n '1,80p'

section "Compose image verification"
if [[ -f "${COMPOSE_FILE}" ]]; then
  if project_compose config --images >/tmp/deploy_compose_images.$$ 2>/tmp/deploy_compose_images.err.$$; then
    missing=0
    while IFS= read -r image; do
      [[ -n "${image}" ]] || continue
      if docker image inspect "${image}" >/dev/null 2>&1; then
        log "Image exists: ${image}"
      else
        warn "Image referenced by compose is missing locally: ${image}"
        missing=$((missing + 1))
      fi
    done < /tmp/deploy_compose_images.$$
    rm -f /tmp/deploy_compose_images.$$ /tmp/deploy_compose_images.err.$$
    if [[ "${missing}" -gt 0 ]]; then
      die "Compose image verification failed: ${missing} image(s) missing."
    fi
  else
    warn "Could not extract compose images using 'docker compose config --images'. Output:"
    cat /tmp/deploy_compose_images.err.$$ >&2 || true
    rm -f /tmp/deploy_compose_images.$$ /tmp/deploy_compose_images.err.$$
  fi
else
  warn "Compose file not found; skipping compose image verification: ${COMPOSE_FILE}"
fi

section "Result"
log "Docker image loading step completed."
