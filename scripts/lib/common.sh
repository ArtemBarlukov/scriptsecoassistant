#!/usr/bin/env bash
# Common helpers for deployment scripts.

set -Eeuo pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_LIB_DIR}/.." && pwd)"
DEPLOY_KIT_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"

CONFIG_FILE="${CONFIG_FILE:-${DEPLOY_KIT_DIR}/deploy.conf}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

expand_user_path() {
  local p="${1:-}"
  case "${p}" in
    "~") printf '%s' "${HOME}" ;;
    "~/"*) printf '%s/%s' "${HOME}" "${p#~/}" ;;
    *) printf '%s' "${p}" ;;
  esac
}

PROJECT_DIR="$(expand_user_path "${PROJECT_DIR:-/opt/ecoassistant}")"
PROJECT_USER="${PROJECT_USER:-${SUDO_USER:-${USER:-root}}}"
COMPOSE_FILE="$(expand_user_path "${COMPOSE_FILE:-${PROJECT_DIR}/docker-compose.yml}")"
ENV_FILE="$(expand_user_path "${ENV_FILE:-${PROJECT_DIR}/.env}")"
ENV_TEMPLATE_FILE="$(expand_user_path "${ENV_TEMPLATE_FILE:-${PROJECT_DIR}/.env.example}")"
IMAGE_ARCHIVE_DIR="$(expand_user_path "${IMAGE_ARCHIVE_DIR:-${PROJECT_DIR}/images}")"
BACKUP_DIR="$(expand_user_path "${BACKUP_DIR:-${PROJECT_DIR}/backups}")"
DB_DUMP_FILE="$(expand_user_path "${DB_DUMP_FILE:-${BACKUP_DIR}/dump.sql}")"
LOG_DIR="$(expand_user_path "${LOG_DIR:-${PROJECT_DIR}/logs}")"

REQUIRED_PORTS="${REQUIRED_PORTS:-80 443}"

DB_TYPE="${DB_TYPE:-postgres}"
DB_SERVICE="${DB_SERVICE:-db}"
DB_NAME="${DB_NAME:-ecoassistant}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD_ENV_NAME="${DB_PASSWORD_ENV_NAME:-POSTGRES_PASSWORD}"
DB_PASSWORD="${DB_PASSWORD:-}"
CHECK_TABLES="${CHECK_TABLES:-}"

BACKEND_SERVICE="${BACKEND_SERVICE:-backend}"
HTTP_ROOT_URL="${HTTP_ROOT_URL:-http://127.0.0.1/}"
FAISS_STATUS_URL="${FAISS_STATUS_URL:-http://127.0.0.1/faiss_status}"
BACKEND_HEALTH_URL="${BACKEND_HEALTH_URL:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
MAX_API_TOKEN="${MAX_API_TOKEN:-}"
MAX_API_CHECK_URL="${MAX_API_CHECK_URL:-}"
RETAG_RULES="${RETAG_RULES:-}"

# Source server settings for pull-based synchronization.
SOURCE_SERVER_HOST="${SOURCE_SERVER_HOST:-}"
SOURCE_SERVER_USER="${SOURCE_SERVER_USER:-root}"
SOURCE_SERVER_PORT="${SOURCE_SERVER_PORT:-22}"
SOURCE_SERVER_PROJECT_DIR="${SOURCE_SERVER_PROJECT_DIR:-/opt/ecoassistant}"
SOURCE_SERVER_IMAGE_DIR="${SOURCE_SERVER_IMAGE_DIR:-${SOURCE_SERVER_PROJECT_DIR}/images}"
SOURCE_SERVER_BACKUP_DIR="${SOURCE_SERVER_BACKUP_DIR:-${SOURCE_SERVER_PROJECT_DIR}/backups}"
SOURCE_SERVER_SSH_KEY="$(expand_user_path "${SOURCE_SERVER_SSH_KEY:-}")"
SOURCE_SERVER_SSH_OPTIONS="${SOURCE_SERVER_SSH_OPTIONS:-}"

# What to copy from the source project directory before docker load.
# Directories are copied only if they exist on the source server.
SYNC_PROJECT_FILES="${SYNC_PROJECT_FILES:-docker-compose.yml compose.yml .env .env.example}"
SYNC_PROJECT_DIRS="${SYNC_PROJECT_DIRS:-nginx config configs certbot data prompts faiss}"
COPY_ENV_FROM_SOURCE="${COPY_ENV_FROM_SOURCE:-true}"
COPY_DB_DUMP_FROM_SOURCE="${COPY_DB_DUMP_FROM_SOURCE:-false}"
SOURCE_DB_DUMP_FILE="${SOURCE_DB_DUMP_FILE:-${SOURCE_SERVER_BACKUP_DIR}/dump.sql}"

log()  { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  local cmd="$1"
  have_cmd "${cmd}" || die "Required command is missing: ${cmd}"
}

sudo_cmd() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif have_cmd sudo; then
    sudo "$@"
  else
    die "Need root privileges or sudo for command: $*"
  fi
}

can_sudo_without_password() {
  [[ "${EUID}" -eq 0 ]] && return 0
  have_cmd sudo && sudo -n true >/dev/null 2>&1
}

mkdir_p() {
  # Prefer direct mkdir. This supports deployments under /home/<user> without sudo.
  if mkdir -p "$@" 2>/dev/null; then
    return 0
  fi
  sudo_cmd mkdir -p "$@"
}

maybe_chown_project_dir() {
  local dir="$1"
  local user="$2"
  [[ -n "${dir}" && -n "${user}" ]] || return 0
  id "${user}" >/dev/null 2>&1 || { warn "Project user does not exist: ${user}. Directory ownership was not changed."; return 0; }
  if [[ "${EUID}" -eq 0 ]] || can_sudo_without_password; then
    sudo_cmd chown -R "${user}:${user}" "${dir}" || warn "Could not chown ${dir} to ${user}."
  else
    info "No root/passwordless sudo; skipping chown for ${dir}. This is OK when deploying inside user's home directory."
  fi
}

read_env_var() {
  local key="$1"
  local file="${2:-${ENV_FILE}}"
  [[ -f "${file}" ]] || return 0

  local line value
  line="$(grep -E "^[[:space:]]*${key}=" "${file}" | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 0

  value="${line#*=}"
  value="${value%%#*}"
  value="${value%$'\r'}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  printf '%s' "${value}"
}

load_optional_secret_defaults() {
  if [[ -z "${DB_PASSWORD}" ]]; then
    DB_PASSWORD="$(read_env_var "${DB_PASSWORD_ENV_NAME}" || true)"
  fi

  if [[ -z "${TELEGRAM_BOT_TOKEN}" ]]; then
    TELEGRAM_BOT_TOKEN="$(read_env_var "TELEGRAM_BOT_TOKEN" || true)"
  fi
  if [[ -z "${TELEGRAM_BOT_TOKEN}" ]]; then
    TELEGRAM_BOT_TOKEN="$(read_env_var "BOT_TOKEN" || true)"
  fi
  if [[ -z "${TELEGRAM_BOT_TOKEN}" ]]; then
    TELEGRAM_BOT_TOKEN="$(read_env_var "TELEGRAM_TOKEN" || true)"
  fi

  if [[ -z "${MAX_API_TOKEN}" ]]; then
    MAX_API_TOKEN="$(read_env_var "MAX_API_TOKEN" || true)"
  fi
}

compose_cmd() {
  if have_cmd docker && docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif have_cmd docker-compose; then
    docker-compose "$@"
  else
    die "Docker Compose is not installed. Run 02_prepare_server.sh first or install Docker Compose manually."
  fi
}

project_compose() {
  [[ -f "${COMPOSE_FILE}" ]] || die "Compose file not found: ${COMPOSE_FILE}"

  local args=("-f" "${COMPOSE_FILE}")
  if [[ -f "${ENV_FILE}" ]]; then
    args+=("--env-file" "${ENV_FILE}")
  fi

  compose_cmd "${args[@]}" "$@"
}

assert_project_dir() {
  [[ -d "${PROJECT_DIR}" ]] || die "Project directory does not exist: ${PROJECT_DIR}"
}

port_listener() {
  local port="$1"
  if have_cmd ss; then
    ss -H -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print}' || true
  elif have_cmd lsof; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
  else
    warn "Neither ss nor lsof is installed; cannot inspect port ${port}."
  fi
}

curl_status() {
  local url="$1"
  local timeout="${2:-10}"
  curl -k -sS -o /tmp/deploy_check_body.$$ -w '%{http_code}' --connect-timeout "${timeout}" --max-time "${timeout}" "${url}"
}

show_config_summary() {
  cat <<SUMMARY
Project directory : ${PROJECT_DIR}
Compose file      : ${COMPOSE_FILE}
Env file          : ${ENV_FILE}
Images directory  : ${IMAGE_ARCHIVE_DIR}
Backup directory  : ${BACKUP_DIR}
DB type/service   : ${DB_TYPE}/${DB_SERVICE}
DB name/user      : ${DB_NAME}/${DB_USER}
Required ports    : ${REQUIRED_PORTS}
SUMMARY
}
