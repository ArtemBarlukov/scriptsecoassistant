#!/usr/bin/env bash
# 04_restore_db.sh
# Starts the DB service, restores SQL/custom dumps, and checks tables/counts.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
load_optional_secret_defaults

section() { printf '\n===== %s =====\n' "$1"; }

postgres_exec() {
  if [[ -n "${DB_PASSWORD}" ]]; then
    project_compose exec -T -e PGPASSWORD="${DB_PASSWORD}" "${DB_SERVICE}" "$@"
  else
    project_compose exec -T "${DB_SERVICE}" "$@"
  fi
}

wait_for_postgres() {
  local attempts="${1:-60}"
  local i
  for i in $(seq 1 "${attempts}"); do
    if postgres_exec pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null 2>&1; then
      log "PostgreSQL is ready."
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_mysql() {
  local attempts="${1:-60}"
  local i
  for i in $(seq 1 "${attempts}"); do
    if project_compose exec -T "${DB_SERVICE}" mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1; then
      log "MySQL/MariaDB is ready."
      return 0
    fi
    sleep 2
  done
  return 1
}

section "Configuration"
show_config_summary

section "Starting database service"
require_cmd docker
project_compose up -d "${DB_SERVICE}"
project_compose ps "${DB_SERVICE}"

section "Waiting for database readiness"
case "${DB_TYPE}" in
  postgres|postgresql)
    wait_for_postgres || die "PostgreSQL did not become ready in time."
    ;;
  mysql|mariadb)
    wait_for_mysql || die "MySQL/MariaDB did not become ready in time."
    ;;
  *)
    die "Unsupported DB_TYPE=${DB_TYPE}. Supported values: postgres, mysql, mariadb."
    ;;
esac

section "Restoring database dump"
[[ -f "${DB_DUMP_FILE}" ]] || die "Database dump file not found: ${DB_DUMP_FILE}"

case "${DB_TYPE}" in
  postgres|postgresql)
    case "${DB_DUMP_FILE}" in
      *.dump|*.backup)
        info "Detected PostgreSQL custom-format dump. Using pg_restore."
        if [[ -n "${DB_PASSWORD}" ]]; then
          project_compose exec -T -e PGPASSWORD="${DB_PASSWORD}" "${DB_SERVICE}" pg_restore --clean --if-exists -U "${DB_USER}" -d "${DB_NAME}" < "${DB_DUMP_FILE}"
        else
          project_compose exec -T "${DB_SERVICE}" pg_restore --clean --if-exists -U "${DB_USER}" -d "${DB_NAME}" < "${DB_DUMP_FILE}"
        fi
        ;;
      *)
        info "Detected SQL-like dump. Using psql."
        if [[ -n "${DB_PASSWORD}" ]]; then
          project_compose exec -T -e PGPASSWORD="${DB_PASSWORD}" "${DB_SERVICE}" psql -v ON_ERROR_STOP=1 -U "${DB_USER}" -d "${DB_NAME}" < "${DB_DUMP_FILE}"
        else
          project_compose exec -T "${DB_SERVICE}" psql -v ON_ERROR_STOP=1 -U "${DB_USER}" -d "${DB_NAME}" < "${DB_DUMP_FILE}"
        fi
        ;;
    esac
    ;;
  mysql|mariadb)
    mysql_password_args=()
    if [[ -n "${DB_PASSWORD}" ]]; then
      mysql_password_args=(-p"${DB_PASSWORD}")
    fi
    project_compose exec -T "${DB_SERVICE}" mysql -u "${DB_USER}" "${mysql_password_args[@]}" "${DB_NAME}" < "${DB_DUMP_FILE}"
    ;;
esac
log "Database dump restored from ${DB_DUMP_FILE}."

section "Tables and counts"
case "${DB_TYPE}" in
  postgres|postgresql)
    info "Public tables:"
    postgres_exec psql -U "${DB_USER}" -d "${DB_NAME}" -Atc "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;" || true

    if [[ -n "${CHECK_TABLES}" ]]; then
      for table in ${CHECK_TABLES}; do
        count="$(postgres_exec psql -U "${DB_USER}" -d "${DB_NAME}" -Atc "SELECT COUNT(*) FROM ${table};" 2>/dev/null || true)"
        if [[ -n "${count}" ]]; then
          log "${table}: ${count} row(s)"
        else
          warn "Could not count table: ${table}"
        fi
      done
    else
      warn "CHECK_TABLES is empty. Configure it in deploy.conf to validate important tables by row count."
    fi
    ;;
  mysql|mariadb)
    info "Tables:"
    project_compose exec -T "${DB_SERVICE}" mysql -u "${DB_USER}" ${DB_PASSWORD:+-p"${DB_PASSWORD}"} -N -e "SHOW TABLES FROM ${DB_NAME};" || true

    if [[ -n "${CHECK_TABLES}" ]]; then
      for table in ${CHECK_TABLES}; do
        count="$(project_compose exec -T "${DB_SERVICE}" mysql -u "${DB_USER}" ${DB_PASSWORD:+-p"${DB_PASSWORD}"} -N -e "SELECT COUNT(*) FROM ${DB_NAME}.${table};" 2>/dev/null || true)"
        if [[ -n "${count}" ]]; then
          log "${table}: ${count} row(s)"
        else
          warn "Could not count table: ${table}"
        fi
      done
    else
      warn "CHECK_TABLES is empty. Configure it in deploy.conf to validate important tables by row count."
    fi
    ;;
esac

section "Result"
log "Database restore step completed."
