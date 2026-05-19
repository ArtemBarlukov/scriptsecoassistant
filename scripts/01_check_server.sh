#!/usr/bin/env bash
# 01_check_server.sh
# Checks whether the target server is suitable for deployment.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

problems=0

section() { printf '\n===== %s =====\n' "$1"; }
mark_problem() { problems=$((problems + 1)); warn "$*"; }

section "Configuration"
show_config_summary

section "OS"
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  echo "OS              : ${PRETTY_NAME:-unknown}"
  echo "ID/VERSION      : ${ID:-unknown}/${VERSION_ID:-unknown}"
else
  mark_problem "/etc/os-release not found; cannot identify Linux distribution."
fi

echo "Kernel          : $(uname -srmo)"

section "Architecture"
arch="$(uname -m)"
echo "Architecture    : ${arch}"
case "${arch}" in
  x86_64|amd64|aarch64|arm64) log "Architecture is common for Docker deployments: ${arch}" ;;
  *) warn "Uncommon architecture: ${arch}. Verify that Docker images were built for this CPU architecture." ;;
esac

section "CPU/RAM"
if have_cmd lscpu; then
  model="$(lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
  sockets="$(lscpu | awk -F: '/Socket\(s\)/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
  echo "CPU model       : ${model:-unknown}"
  echo "CPU sockets     : ${sockets:-unknown}"
fi

echo "CPU cores       : $(nproc 2>/dev/null || echo unknown)"
if have_cmd free; then
  free -h
else
  mark_problem "free command not found; cannot inspect RAM."
fi

section "Disk"
if [[ -d "${PROJECT_DIR}" ]]; then
  df -h "${PROJECT_DIR}"
else
  warn "Project directory does not exist yet: ${PROJECT_DIR}; checking root filesystem instead."
  df -h /
fi

section "Ports"
for port in ${REQUIRED_PORTS}; do
  listener="$(port_listener "${port}")"
  if [[ -n "${listener}" ]]; then
    warn "Port ${port} is already in LISTEN state:"
    echo "${listener}"
  else
    log "Port ${port} is free or not listening locally."
  fi
done

section "Docker"
if have_cmd docker; then
  docker --version
  if docker info >/dev/null 2>&1; then
    log "Docker daemon is available for current user."
  else
    mark_problem "Docker is installed, but current user cannot access the Docker daemon. Check docker service and user permissions."
  fi
else
  warn "Docker is not installed. 02_prepare_server.sh can install it on Debian/Ubuntu-like systems."
fi

if have_cmd docker && docker compose version >/dev/null 2>&1; then
  docker compose version
elif have_cmd docker-compose; then
  docker-compose --version
else
  warn "Docker Compose is not installed."
fi

section "User permissions"
echo "Current user    : $(whoami)"
echo "UID/GID         : $(id -u)/$(id -g)"
echo "Groups          : $(id -nG)"

if [[ "${EUID}" -eq 0 ]]; then
  log "Script is running as root."
elif can_sudo_without_password; then
  log "Current user can run sudo without interactive password prompt."
elif have_cmd sudo; then
  warn "sudo exists, but passwordless sudo is not available. Preparation may ask for a password."
else
  mark_problem "Current user is not root and sudo is not installed."
fi

if id -nG | tr ' ' '\n' | grep -qx docker; then
  log "Current user is in docker group."
else
  warn "Current user is not in docker group. If Docker is used without sudo, re-login may be required after 02_prepare_server.sh."
fi

section "Result"
if [[ "${problems}" -eq 0 ]]; then
  log "Server check completed. Critical problems were not detected by this script."
else
  die "Server check completed with ${problems} critical problem(s). Review warnings/errors above."
fi
