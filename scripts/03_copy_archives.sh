#!/usr/bin/env bash
# 00_copy_archives.sh
# Pulls required deployment files and Docker image archives from source server.
# Run this script on the NEW/TARGET server.
# This script does not copy raw PostgreSQL data directories.
# It generates image-based docker-compose.yml for deployment from preloaded images.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

section() { printf '\n===== %s =====\n' "$1"; }

if ! declare -F mkdir_p >/dev/null 2>&1; then
  mkdir_p() {
    mkdir -p "$@"
  }
fi

DEPLOY_CONF_FILE="${SCRIPT_DIR}/../deploy.conf"

SOURCE_SERVER_HOST="${SOURCE_SERVER_HOST:-}"
SOURCE_SERVER_USER="${SOURCE_SERVER_USER:-root}"
SOURCE_SERVER_PORT="${SOURCE_SERVER_PORT:-22}"
SOURCE_SERVER_PROJECT_DIR="${SOURCE_SERVER_PROJECT_DIR:-/opt/ecoassistant}"
SOURCE_SERVER_IMAGE_DIR="${SOURCE_SERVER_IMAGE_DIR:-/opt/ecoassistant/images}"
SOURCE_SERVER_SSH_KEY="${SOURCE_SERVER_SSH_KEY:-}"
SOURCE_SERVER_SSH_OPTIONS="${SOURCE_SERVER_SSH_OPTIONS:-}"

TELEGRAM_IMAGE="${TELEGRAM_IMAGE:-ecoassistant-telegram:latest}"
BACKEND_IMAGE="${BACKEND_IMAGE:-ecoassistant-backend:latest}"
DB_IMAGE="${DB_IMAGE:-ecoassistant-db:latest}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:alpine}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:alpine}"

# Only files required by the generated image-based compose.
# These paths are relative to SOURCE_SERVER_PROJECT_DIR.
REQUIRED_PROJECT_FILES="${REQUIRED_PROJECT_FILES:-EcoBotProject/TelegramBot/.env db_custom/.env db_custom/init.sql salut_bot/.env nginx/nginx.conf}"

# Optional files are copied if they exist.
OPTIONAL_PROJECT_FILES="${OPTIONAL_PROJECT_FILES:-.env .env.example docker-compose.yml}"

# Safe directories only. Do not put data/pgdata/postgres here.
SAFE_PROJECT_DIRS="${SAFE_PROJECT_DIRS:-certbot/www maps}"

# Directories that must exist on target, but should not be copied from source.
TARGET_CREATE_DIRS="${TARGET_CREATE_DIRS:-logs data data/postgres_data maps certbot/www}"

set_deploy_conf_value() {
  local key="$1"
  local value="$2"
  local escaped_value

  if [[ ! -f "${DEPLOY_CONF_FILE}" ]]; then
    warn "deploy.conf was not found: ${DEPLOY_CONF_FILE}; cannot persist ${key}."
    return 0
  fi

  escaped_value="$(printf '%s' "${value}" | sed 's/[\/&|]/\\&/g')"

  if grep -qE "^${key}=" "${DEPLOY_CONF_FILE}"; then
    sed -i "s|^${key}=.*|${key}=\"${escaped_value}\"|g" "${DEPLOY_CONF_FILE}"
  else
    printf '%s="%s"\n' "${key}" "${value}" >> "${DEPLOY_CONF_FILE}"
  fi
}

ensure_source_ssh_key() {
  local default_key="${HOME}/.ssh/ecoassistant_source"
  local public_key
  local source_target="${SOURCE_SERVER_USER}@${SOURCE_SERVER_HOST}"

  if [[ -z "${SOURCE_SERVER_SSH_KEY}" ]]; then
    SOURCE_SERVER_SSH_KEY="${default_key}"
    set_deploy_conf_value "SOURCE_SERVER_SSH_KEY" "${SOURCE_SERVER_SSH_KEY}"
    log "SOURCE_SERVER_SSH_KEY was empty; set to ${SOURCE_SERVER_SSH_KEY}"
  fi

  mkdir -p "$(dirname "${SOURCE_SERVER_SSH_KEY}")"
  chmod 700 "$(dirname "${SOURCE_SERVER_SSH_KEY}")"

  if [[ ! -f "${SOURCE_SERVER_SSH_KEY}" ]]; then
    section "SSH key generation"
    info "SSH key does not exist. Generating: ${SOURCE_SERVER_SSH_KEY}"

    ssh-keygen \
      -t ed25519 \
      -f "${SOURCE_SERVER_SSH_KEY}" \
      -N "" \
      -C "ecoassistant-deploy@$(hostname)"

    chmod 600 "${SOURCE_SERVER_SSH_KEY}"
    chmod 644 "${SOURCE_SERVER_SSH_KEY}.pub"

    log "SSH key generated."
  else
    log "SSH key already exists: ${SOURCE_SERVER_SSH_KEY}"
  fi

  public_key="${SOURCE_SERVER_SSH_KEY}.pub"
  [[ -f "${public_key}" ]] || die "Public key file does not exist: ${public_key}"

  section "SSH key authorization check"

  if ssh \
      -i "${SOURCE_SERVER_SSH_KEY}" \
      -p "${SOURCE_SERVER_PORT}" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      "${source_target}" \
      "echo OK" >/dev/null 2>&1; then
    log "SSH key authentication already works for ${source_target}."
    return 0
  fi

  warn "SSH key authentication is not configured on source server yet."
  info "The source server password will be requested once to install the public key."

  cat "${public_key}" | ssh \
    -p "${SOURCE_SERVER_PORT}" \
    -o StrictHostKeyChecking=accept-new \
    "${source_target}" \
    'umask 077;
     mkdir -p ~/.ssh;
     touch ~/.ssh/authorized_keys;
     IFS= read -r key;
     grep -qxF "$key" ~/.ssh/authorized_keys || printf "%s\n" "$key" >> ~/.ssh/authorized_keys;
     chmod 700 ~/.ssh;
     chmod 600 ~/.ssh/authorized_keys'

  if ssh \
      -i "${SOURCE_SERVER_SSH_KEY}" \
      -p "${SOURCE_SERVER_PORT}" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      "${source_target}" \
      "echo OK" >/dev/null 2>&1; then
    log "SSH key was installed successfully."
  else
    die "SSH key installation failed. Check source server SSH settings and user permissions."
  fi
}

copy_required_file() {
  local rel_path="$1"
  local src="${SOURCE_SERVER_PROJECT_DIR}/${rel_path}"
  local dst="${PROJECT_DIR}/${rel_path}"
  local dst_dir

  dst_dir="$(dirname "${dst}")"
  mkdir_p "${dst_dir}"

  if ssh "${ssh_opts[@]}" "${SOURCE}" "test -f '${src}'"; then
    info "Copying required file: ${rel_path}"
    scp "${scp_opts[@]}" "${SOURCE}:${src}" "${dst}"
    log "Copied required file: ${rel_path}"
  else
    die "Required source file is missing: ${src}"
  fi
}

copy_optional_file() {
  local rel_path="$1"
  local src="${SOURCE_SERVER_PROJECT_DIR}/${rel_path}"
  local dst="${PROJECT_DIR}/${rel_path}"
  local dst_dir

  dst_dir="$(dirname "${dst}")"
  mkdir_p "${dst_dir}"

  if ssh "${ssh_opts[@]}" "${SOURCE}" "test -f '${src}'"; then
    if [[ "${rel_path}" == "docker-compose.yml" ]]; then
      info "Copying source docker-compose.yml as docker-compose.source.yml"
      scp "${scp_opts[@]}" "${SOURCE}:${src}" "${PROJECT_DIR}/docker-compose.source.yml"
      log "Copied source compose backup: docker-compose.source.yml"
    else
      info "Copying optional file: ${rel_path}"
      scp "${scp_opts[@]}" "${SOURCE}:${src}" "${dst}"
      log "Copied optional file: ${rel_path}"
    fi
  else
    info "Optional source file not found, skipping: ${src}"
  fi
}

copy_safe_dir() {
  local rel_path="$1"
  local src="${SOURCE_SERVER_PROJECT_DIR}/${rel_path}"
  local dst="${PROJECT_DIR}/${rel_path}"
  local dst_parent

  case "${rel_path}" in
    data|data/*|pgdata|pgdata/*|postgres|postgres/*|postgresql|postgresql/*|db|db/*|database|database/*|volumes|volumes/*)
      warn "Skipping unsafe raw data directory: ${rel_path}"
      return 0
      ;;
  esac

  dst_parent="$(dirname "${dst}")"
  mkdir_p "${dst_parent}"

  if ssh "${ssh_opts[@]}" "${SOURCE}" "test -d '${src}'"; then
    info "Copying safe directory: ${rel_path}"
    rm -rf "${dst}"
    scp "${scp_opts[@]}" -r "${SOURCE}:${src}" "${dst_parent}/"
    log "Copied safe directory: ${rel_path}"
  else
    info "Safe source directory not found, skipping: ${src}"
  fi
}

write_image_compose() {
  section "Generating image-based docker-compose.yml"

  if [[ -f "${COMPOSE_FILE}" ]]; then
    cp "${COMPOSE_FILE}" "${COMPOSE_FILE}.before-image-compose.$(date +%Y%m%d_%H%M%S)"
  fi

  cat > "${COMPOSE_FILE}" <<COMPOSE_EOF
services:
  telegram:
    image: ${TELEGRAM_IMAGE}
    restart: always
    env_file:
      - ./EcoBotProject/TelegramBot/.env
    volumes:
      - ./logs:/app/logs
      - ./data:/app/data
    environment:
      - PYTHONUNBUFFERED=1
    extra_hosts:
      - "host.docker.internal:host-gateway"

  redis:
    image: ${REDIS_IMAGE}
    restart: always

  db:
    image: ${DB_IMAGE}
    restart: always
    env_file:
      - ./db_custom/.env
    volumes:
      - ./data/postgres_data:/var/lib/postgresql/data
      - ./db_custom/init.sql:/docker-entrypoint-initdb.d/init.sql

  backend:
    image: ${BACKEND_IMAGE}
    restart: always
    depends_on:
      - db
      - redis
    env_file:
      - ./salut_bot/.env
    volumes:
      - ./maps:/app/maps
    environment:
      - PYTHONUNBUFFERED=1
      - DB_HOST=db

  nginx:
    image: ${NGINX_IMAGE}
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - /dev/null:/etc/nginx/conf.d/default.conf
      - ./maps:/var/www/maps
      - ./certbot/www:/var/www/certbot
      - /etc/letsencrypt:/etc/letsencrypt:ro
    depends_on:
      - backend
COMPOSE_EOF

  log "Generated image-based compose file: ${COMPOSE_FILE}"
}

section "Configuration"
show_config_summary

SOURCE="${SOURCE_SERVER_USER}@${SOURCE_SERVER_HOST}"

cat <<SUMMARY
Source server          : ${SOURCE}:${SOURCE_SERVER_PORT}
Source project dir     : ${SOURCE_SERVER_PROJECT_DIR}
Source images dir      : ${SOURCE_SERVER_IMAGE_DIR}
Target project dir     : ${PROJECT_DIR}
Target images dir      : ${IMAGE_ARCHIVE_DIR}
Required files         : ${REQUIRED_PROJECT_FILES}
Optional files         : ${OPTIONAL_PROJECT_FILES}
Safe dirs              : ${SAFE_PROJECT_DIRS}
Target dirs to create  : ${TARGET_CREATE_DIRS}
Telegram image         : ${TELEGRAM_IMAGE}
Backend image          : ${BACKEND_IMAGE}
DB image               : ${DB_IMAGE}
Redis image            : ${REDIS_IMAGE}
Nginx image            : ${NGINX_IMAGE}
SUMMARY

[[ -n "${SOURCE_SERVER_HOST}" ]] || die "SOURCE_SERVER_HOST is empty. Set it in deploy.conf."
[[ -n "${SOURCE_SERVER_USER}" ]] || die "SOURCE_SERVER_USER is empty. Set it in deploy.conf."
[[ -n "${SOURCE_SERVER_PORT}" ]] || die "SOURCE_SERVER_PORT is empty. Set it in deploy.conf."
[[ -n "${SOURCE_SERVER_PROJECT_DIR}" ]] || die "SOURCE_SERVER_PROJECT_DIR is empty. Set it in deploy.conf."
[[ -n "${SOURCE_SERVER_IMAGE_DIR}" ]] || die "SOURCE_SERVER_IMAGE_DIR is empty. Set it in deploy.conf."

section "Required commands"
require_cmd ssh
require_cmd scp
require_cmd ssh-keygen
log "Local ssh, scp and ssh-keygen are available."

ensure_source_ssh_key

CONTROL_SOCKET="/tmp/ecoassistant_ssh_${SOURCE_SERVER_USER}_${SOURCE_SERVER_HOST}_${SOURCE_SERVER_PORT}.sock"

ssh_opts=(
  -p "${SOURCE_SERVER_PORT}"
  -i "${SOURCE_SERVER_SSH_KEY}"
  -o ControlMaster=auto
  -o ControlPath="${CONTROL_SOCKET}"
  -o ControlPersist=10m
)

scp_opts=(
  -P "${SOURCE_SERVER_PORT}"
  -i "${SOURCE_SERVER_SSH_KEY}"
  -o ControlMaster=auto
  -o ControlPath="${CONTROL_SOCKET}"
  -o ControlPersist=10m
)

if [[ -n "${SOURCE_SERVER_SSH_OPTIONS}" ]]; then
  # shellcheck disable=SC2206
  extra_ssh_opts=( ${SOURCE_SERVER_SSH_OPTIONS} )
  ssh_opts+=( "${extra_ssh_opts[@]}" )
  scp_opts+=( "${extra_ssh_opts[@]}" )
fi

section "Opening SSH master connection"
if ssh -O check "${ssh_opts[@]}" "${SOURCE}" >/dev/null 2>&1; then
  log "SSH master connection already exists."
else
  rm -f "${CONTROL_SOCKET}"
  info "Opening SSH master connection by key."
  ssh -MNf "${ssh_opts[@]}" "${SOURCE}"
  log "SSH master connection opened."
fi

section "Source checks"
ssh "${ssh_opts[@]}" "${SOURCE}" "test -d '${SOURCE_SERVER_PROJECT_DIR}'"
log "Source project directory exists: ${SOURCE_SERVER_PROJECT_DIR}"

ssh "${ssh_opts[@]}" "${SOURCE}" "test -d '${SOURCE_SERVER_IMAGE_DIR}'"
log "Source image directory exists: ${SOURCE_SERVER_IMAGE_DIR}"

section "Preparing target directories"
mkdir_p "${PROJECT_DIR}" "${IMAGE_ARCHIVE_DIR}" "${BACKUP_DIR}" "${LOG_DIR}"
for dir in ${TARGET_CREATE_DIRS}; do
  [[ -n "${dir}" ]] || continue
  mkdir_p "${PROJECT_DIR}/${dir}"
done
log "Target directories are ready."

section "Copying required project files"
for file in ${REQUIRED_PROJECT_FILES}; do
  [[ -n "${file}" ]] || continue
  copy_required_file "${file}"
done

section "Copying optional project files"
for file in ${OPTIONAL_PROJECT_FILES}; do
  [[ -n "${file}" ]] || continue
  copy_optional_file "${file}"
done

section "Copying safe project directories"
for dir in ${SAFE_PROJECT_DIRS}; do
  [[ -n "${dir}" ]] || continue
  copy_safe_dir "${dir}"
done

write_image_compose

section "Copying Docker image archives"
mapfile -t remote_archives < <(
  ssh "${ssh_opts[@]}" "${SOURCE}" \
    "find '${SOURCE_SERVER_IMAGE_DIR}' -maxdepth 1 -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' \) -printf '%f\n' | sort"
)

if [[ "${#remote_archives[@]}" -eq 0 ]]; then
  die "No Docker image archives found on source server in ${SOURCE_SERVER_IMAGE_DIR}."
fi

info "Found archive(s) on source server:"
printf ' - %s\n' "${remote_archives[@]}"

for archive in "${remote_archives[@]}"; do
  [[ -n "${archive}" ]] || continue
  info "Copying archive: ${archive}"
  scp "${scp_opts[@]}" "${SOURCE}:${SOURCE_SERVER_IMAGE_DIR}/${archive}" "${IMAGE_ARCHIVE_DIR}/"
done

section "Target checks"
missing=0

for path in \
  "${COMPOSE_FILE}" \
  "${PROJECT_DIR}/EcoBotProject/TelegramBot/.env" \
  "${PROJECT_DIR}/db_custom/.env" \
  "${PROJECT_DIR}/db_custom/init.sql" \
  "${PROJECT_DIR}/salut_bot/.env" \
  "${PROJECT_DIR}/nginx/nginx.conf"
do
  if [[ -f "${path}" ]]; then
    log "Required target file exists: ${path}"
  else
    warn "Required target file is missing: ${path}"
    missing=$((missing + 1))
  fi
done

mapfile -t target_archives < <(
  find "${IMAGE_ARCHIVE_DIR}" -maxdepth 1 -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' \) | sort
)

if [[ "${#target_archives[@]}" -eq 0 ]]; then
  die "No archives were found in target directory: ${IMAGE_ARCHIVE_DIR}"
fi

info "Archive(s) on target server:"
printf ' - %s\n' "${target_archives[@]}"

if [[ "${missing}" -gt 0 ]]; then
  die "Target check failed: ${missing} required file(s) missing."
fi

section "Result"
log "Required deployment files and Docker image archives were pulled from ${SOURCE}."
log "Generated compose uses preloaded images instead of build paths."
log "Next step: run scripts/03_load_images.sh on this target server."
