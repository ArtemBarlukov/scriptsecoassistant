#!/usr/bin/env bash
# 02_prepare_server.sh
# Prepares target server for EcoAssistant deployment.
# Safe for Ansible/raw mode: does not ask sudo password interactively.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

section() { printf '\n===== %s =====\n' "$1"; }

NON_INTERACTIVE="${NON_INTERACTIVE:-true}"
ALLOW_SUDO="${ALLOW_SUDO:-false}"
ALLOW_DOCKER_INSTALL="${ALLOW_DOCKER_INSTALL:-false}"

safe_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
    return $?
  fi

  if [[ "${ALLOW_SUDO}" != "true" ]]; then
    warn "Skipping privileged command because ALLOW_SUDO=${ALLOW_SUDO}: $*"
    return 1
  fi

  if sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
    return $?
  fi

  warn "Passwordless sudo is not available; skipping privileged command: $*"
  return 1
}

install_docker_debian_like() {
  section "Installing Docker packages"

  if [[ "${ALLOW_DOCKER_INSTALL}" != "true" ]]; then
    die "Docker is not installed and ALLOW_DOCKER_INSTALL=${ALLOW_DOCKER_INSTALL}. Install Docker manually or rerun with ALLOW_DOCKER_INSTALL=true and sudo/root access."
  fi

  safe_sudo apt-get update || die "Could not run apt-get update."
  safe_sudo apt-get install -y ca-certificates curl gnupg lsb-release docker.io docker-compose-plugin || die "Could not install Docker packages."
  safe_sudo systemctl enable --now docker || warn "Could not enable/start docker via systemctl. Check init system manually."
}

section "Configuration"
show_config_summary

section "Runtime mode"
info "NON_INTERACTIVE=${NON_INTERACTIVE}"
info "ALLOW_SUDO=${ALLOW_SUDO}"
info "ALLOW_DOCKER_INSTALL=${ALLOW_DOCKER_INSTALL}"

section "Docker installation"
if have_cmd docker; then
  log "Docker is already installed: $(docker --version)"
else
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
      ubuntu|debian|astra)
        install_docker_debian_like
        ;;
      *)
        die "Docker is not installed. Automatic installation is implemented only for Debian/Ubuntu/Astra-like systems. Detected: ${ID:-unknown}."
        ;;
    esac
  else
    die "Cannot detect OS. Install Docker manually and rerun this script."
  fi
fi

section "Docker Compose check"
if have_cmd docker && docker compose version >/dev/null 2>&1; then
  log "Docker Compose plugin is available: $(docker compose version)"
elif have_cmd docker-compose; then
  log "Legacy docker-compose is available: $(docker-compose --version)"
else
  warn "Docker is installed, but Docker Compose was not detected."
  warn "This deployment can still work if scripts/06_up_project.sh uses docker run instead of docker compose."
fi

section "Docker daemon and permissions"
if have_cmd docker && docker info >/dev/null 2>&1; then
  log "Docker daemon is available for current user."
else
  warn "Docker daemon is not available for current user."

  if have_cmd systemctl; then
    safe_sudo systemctl enable --now docker || warn "Could not enable/start docker service without sudo/root."
  fi

  if ! docker info >/dev/null 2>&1; then
    die "Docker daemon is still unavailable for current user. Check Docker service and docker group membership."
  fi
fi

section "Docker group"
if getent group docker >/dev/null 2>&1; then
  if id -nG "${PROJECT_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    log "User ${PROJECT_USER} is already in docker group."
  else
    warn "User ${PROJECT_USER} is not in docker group."

    if [[ "${EUID}" -eq 0 ]] || { [[ "${ALLOW_SUDO}" == "true" ]] && sudo -n true >/dev/null 2>&1; }; then
      safe_sudo usermod -aG docker "${PROJECT_USER}" || warn "Could not add ${PROJECT_USER} to docker group."
      warn "If user was added to docker group, re-login may be required."
    else
      warn "No root/passwordless sudo; cannot add ${PROJECT_USER} to docker group."
    fi
  fi
else
  warn "docker group does not exist."
fi

section "Project directories"
mkdir -p "${PROJECT_DIR}" "${IMAGE_ARCHIVE_DIR}" "${BACKUP_DIR}" "${LOG_DIR}"

if [[ -w "${PROJECT_DIR}" ]]; then
  log "Current user can write to project directory: ${PROJECT_DIR}"
else
  warn "Current user cannot write to ${PROJECT_DIR}."
  warn "Trying to chown only if root/passwordless sudo is available."

  if [[ "${EUID}" -eq 0 ]] || { [[ "${ALLOW_SUDO}" == "true" ]] && sudo -n true >/dev/null 2>&1; }; then
    safe_sudo chown -R "${PROJECT_USER}:${PROJECT_USER}" "${PROJECT_DIR}" || warn "Could not chown ${PROJECT_DIR}."
  fi

  [[ -w "${PROJECT_DIR}" ]] || die "Project directory is not writable: ${PROJECT_DIR}"
fi

log "Project directory prepared: ${PROJECT_DIR}"
log "Image archive directory prepared: ${IMAGE_ARCHIVE_DIR}"
log "Backup directory prepared: ${BACKUP_DIR}"
log "Log directory prepared: ${LOG_DIR}"

section ".env template"
if [[ -f "${ENV_FILE}" ]]; then
  warn "Existing .env was found and will not be overwritten: ${ENV_FILE}"
else
  if [[ ! -f "${ENV_TEMPLATE_FILE}" ]]; then
    cat > "${ENV_TEMPLATE_FILE}" <<'ENVEOF'
# Application environment template.
# Copy this file to .env and replace CHANGE_ME values before starting the project.

# Database
POSTGRES_DB=ecoassistant
POSTGRES_USER=postgres
POSTGRES_PASSWORD=CHANGE_ME
DATABASE_URL=postgresql://postgres:CHANGE_ME@db:5432/ecoassistant

# Bot/API tokens
TELEGRAM_BOT_TOKEN=CHANGE_ME
MAX_API_TOKEN=CHANGE_ME

# Application settings
APP_ENV=production
APP_HOST=0.0.0.0
APP_PORT=8000
ENVEOF
    log "Created env template: ${ENV_TEMPLATE_FILE}"
  else
    log "Env template already exists: ${ENV_TEMPLATE_FILE}"
  fi

  cp "${ENV_TEMPLATE_FILE}" "${ENV_FILE}"
  warn "Created ${ENV_FILE} from template. It can be overwritten later by scripts/03_copy_archives.sh if COPY_ENV_FROM_SOURCE=true."
fi

section "Compose file"
if [[ -f "${COMPOSE_FILE}" ]]; then
  log "Compose file found: ${COMPOSE_FILE}"
else
  warn "Compose file was not found: ${COMPOSE_FILE}"
  warn "It can be pulled from the source server by scripts/03_copy_archives.sh if SOURCE_SERVER_PROJECT_DIR is configured."
fi

section "Result"
log "Server preparation completed."
