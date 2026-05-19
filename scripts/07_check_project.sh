#!/usr/bin/env bash
# 06_check_project.sh
# Checks HTTP endpoints, backend container, Telegram API, and optional MAX API.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
load_optional_secret_defaults

section() { printf '\n===== %s =====\n' "$1"; }

check_url() {
  local name="$1"
  local url="$2"
  local expected_pattern="${3:-^(2|3)[0-9][0-9]$}"

  [[ -n "${url}" ]] || { warn "${name}: URL is empty; skipping."; return 0; }

  info "Checking ${name}: ${url}"
  rm -f /tmp/deploy_check_body.$$
  status="$(curl_status "${url}" 15 || true)"
  body_file="/tmp/deploy_check_body.$$"

  if [[ "${status}" =~ ${expected_pattern} ]]; then
    log "${name}: HTTP ${status}"
  else
    warn "${name}: unexpected HTTP status: ${status:-curl_failed}"
    if [[ -f "${body_file}" ]]; then
      echo "--- response body preview ---"
      head -c 800 "${body_file}" || true
      echo
      echo "--- end preview ---"
    fi
    rm -f "${body_file}"
    return 1
  fi

  rm -f "${body_file}"
}

section "Configuration"
show_config_summary

section "Compose status"
if [[ -f "${COMPOSE_FILE}" ]]; then
  project_compose ps || warn "Could not execute docker compose ps."
else
  warn "Compose file not found: ${COMPOSE_FILE}; skipping compose status."
fi

section "HTTP checks"
failures=0
check_url "root" "${HTTP_ROOT_URL}" || failures=$((failures + 1))
check_url "faiss_status" "${FAISS_STATUS_URL}" || failures=$((failures + 1))
if [[ -n "${BACKEND_HEALTH_URL}" ]]; then
  check_url "backend_health" "${BACKEND_HEALTH_URL}" || failures=$((failures + 1))
else
  info "BACKEND_HEALTH_URL is empty; backend HTTP health URL is not checked separately."
fi

section "Backend service"
if [[ -f "${COMPOSE_FILE}" ]]; then
  backend_id="$(project_compose ps -q "${BACKEND_SERVICE}" 2>/dev/null || true)"
  if [[ -n "${backend_id}" ]]; then
    running="$(docker inspect -f '{{.State.Running}}' "${backend_id}" 2>/dev/null || echo false)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "${backend_id}" 2>/dev/null || echo unknown)"
    if [[ "${running}" == "true" && "${health}" != "unhealthy" ]]; then
      log "Backend service ${BACKEND_SERVICE}: running=${running}, health=${health}"
    else
      warn "Backend service ${BACKEND_SERVICE}: running=${running}, health=${health}"
      failures=$((failures + 1))
    fi
    info "Recent backend logs:"
    project_compose logs --tail=80 --no-color "${BACKEND_SERVICE}" || true
  else
    warn "Backend service was not found in compose or is not running: ${BACKEND_SERVICE}"
    failures=$((failures + 1))
  fi
fi

section "Telegram API"
if [[ -n "${TELEGRAM_BOT_TOKEN}" && "${TELEGRAM_BOT_TOKEN}" != "CHANGE_ME" ]]; then
  tg_body="$(curl -sS --connect-timeout 10 --max-time 15 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" || true)"
  if printf '%s' "${tg_body}" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
    log "Telegram API getMe returned ok=true."
  else
    warn "Telegram API getMe did not return ok=true. Response preview without token:"
    printf '%s\n' "${tg_body}" | head -c 800
    echo
    failures=$((failures + 1))
  fi
else
  warn "Telegram token is empty or CHANGE_ME; Telegram API check skipped."
fi

section "MAX API"
if [[ -n "${MAX_API_TOKEN}" && "${MAX_API_TOKEN}" != "CHANGE_ME" ]]; then
  if [[ -n "${MAX_API_CHECK_URL}" ]]; then
    max_status="$(curl -sS -o /tmp/deploy_max_body.$$ -w '%{http_code}' --connect-timeout 10 --max-time 15 -H "Authorization: Bearer ${MAX_API_TOKEN}" "${MAX_API_CHECK_URL}" || true)"
    if [[ "${max_status}" =~ ^(2|3)[0-9][0-9]$ ]]; then
      log "MAX API check returned HTTP ${max_status}."
    else
      warn "MAX API check returned unexpected HTTP status: ${max_status:-curl_failed}"
      if [[ -f /tmp/deploy_max_body.$$ ]]; then
        head -c 800 /tmp/deploy_max_body.$$ || true
        echo
      fi
      failures=$((failures + 1))
    fi
    rm -f /tmp/deploy_max_body.$$
  else
    warn "MAX_API_TOKEN is set, but MAX_API_CHECK_URL is empty; MAX API check skipped."
  fi
else
  info "MAX API token is empty or CHANGE_ME; MAX API check skipped."
fi

section "Result"
if [[ "${failures}" -eq 0 ]]; then
  log "Project check completed successfully."
else
  die "Project check completed with ${failures} failed check(s)."
fi
