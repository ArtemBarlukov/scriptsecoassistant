cat > /home/ecoassistant/ecoassistant_deploy_scripts/scripts/05_up_project_manual.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/home/ecoassistant/ecoassistant_scrpt}"
NETWORK_NAME="${NETWORK_NAME:-ecoassistant_net}"

cd "${PROJECT_DIR}"

section() {
  printf '\n===== %s =====\n' "$1"
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

log() {
  echo "[OK] $*"
}

info() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

normalize_env_file() {
  local file="$1"
  local backup_file

  [[ -f "${file}" ]] || die "Env file missing: ${file}"

  backup_file="${file}.bak.$(date +%Y%m%d_%H%M%S)"
  cp "${file}" "${backup_file}"

  # Docker --env-file requires KEY=VALUE.
  # This fixes:
  #   MAPS_DIR = ./maps
  # into:
  #   MAPS_DIR=./maps
  sed -i -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*/\1=/' "${file}"

  # Remove Windows CRLF if the file was edited on Windows.
  sed -i 's/\r$//' "${file}"

  # Remove trailing spaces.
  sed -i -E 's/[[:space:]]+$//' "${file}"

  log "Normalized env file: ${file}; backup: ${backup_file}"
}

validate_env_file() {
  local file="$1"
  local bad_lines

  [[ -f "${file}" ]] || die "Env file missing: ${file}"

  bad_lines="$(
    awk -F= '
      /^[[:space:]]*($|#)/ { next }
      {
        key=$1
        if (key ~ /^[[:space:]]/ || key ~ /[[:space:]]$/ || key !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
          print FILENAME ":" FNR ": invalid key [" key "]"
        }
      }
    ' "${file}" || true
  )"

  if [[ -n "${bad_lines}" ]]; then
    echo "${bad_lines}" >&2
    die "Invalid env file format: ${file}"
  fi

  log "Env file format is valid: ${file}"
}

check_telegram_token_format() {
  local file="EcoBotProject/TelegramBot/.env"
  local token

  token="$(awk -F= '/^BOT_TOKEN=/ {print $2}' "${file}" | tail -n 1)"

  if [[ -z "${token}" ]]; then
    warn "BOT_TOKEN is empty in ${file}. Telegram container will probably restart."
    return 0
  fi

  if [[ "${token}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
    log "BOT_TOKEN format looks valid."
  else
    warn "BOT_TOKEN format looks invalid. Telegram container will probably restart."
  fi
}

require_file() {
  local file="$1"
  [[ -f "${file}" ]] || die "${file} missing"
  log "Required file exists: ${file}"
}

write_http_nginx_config() {
  section "Writing HTTP-only nginx config"

  mkdir -p nginx maps

  if [[ -f nginx/nginx.conf ]]; then
    cp nginx/nginx.conf "nginx/nginx.conf.bak.$(date +%Y%m%d_%H%M%S)"
    log "Old nginx config was backed up."
  fi

  cat > nginx/nginx.conf <<'NGINX_EOF'
events {}

http {
    server {
        listen 80;
        server_name _;

        client_max_body_size 50M;

        location /maps/ {
            alias /var/www/maps/;
            autoindex on;
        }

        location / {
            proxy_pass http://backend:5555;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
NGINX_EOF

  log "HTTP-only nginx config was written: ${PROJECT_DIR}/nginx/nginx.conf"
}

section "Checking required files"
require_file "docker-compose.yml"
require_file "EcoBotProject/TelegramBot/.env"
require_file "db_custom/.env"
require_file "db_custom/init.sql"
require_file "salut_bot/.env"

section "Preparing directories"
mkdir -p logs data data/postgres_data maps certbot/www nginx
log "Project directories are ready."

section "Writing nginx config"
write_http_nginx_config
require_file "nginx/nginx.conf"

section "Normalizing env files"
normalize_env_file "salut_bot/.env"
normalize_env_file "EcoBotProject/TelegramBot/.env"
normalize_env_file "db_custom/.env"

section "Validating env files"
validate_env_file "salut_bot/.env"
validate_env_file "EcoBotProject/TelegramBot/.env"
validate_env_file "db_custom/.env"
check_telegram_token_format

section "Checking Docker images"
for image in \
  redis:alpine \
  ecoassistant-db:latest \
  ecoassistant-backend:latest \
  ecoassistant-telegram:latest \
  nginx:alpine
do
  docker image inspect "${image}" >/dev/null 2>&1 || die "Docker image is missing: ${image}"
  log "Docker image exists: ${image}"
done

section "Creating Docker network"
docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1 || docker network create "${NETWORK_NAME}"
log "Docker network is ready: ${NETWORK_NAME}"

section "Removing old containers if they exist"
docker rm -f \
  ecoassistant-nginx \
  ecoassistant-telegram \
  ecoassistant-backend \
  ecoassistant-db \
  ecoassistant-redis \
  >/dev/null 2>&1 || true
log "Old containers removed if they existed."

section "Starting redis"
docker run -d \
  --name ecoassistant-redis \
  --restart always \
  --network "${NETWORK_NAME}" \
  --network-alias redis \
  redis:alpine

section "Starting db"
docker run -d \
  --name ecoassistant-db \
  --restart always \
  --network "${NETWORK_NAME}" \
  --network-alias db \
  --env-file db_custom/.env \
  -v "${PROJECT_DIR}/data/postgres_data:/var/lib/postgresql/data" \
  -v "${PROJECT_DIR}/db_custom/init.sql:/docker-entrypoint-initdb.d/init.sql:ro" \
  ecoassistant-db:latest

section "Waiting for db"
sleep 10

section "Starting backend"
docker run -d \
  --name ecoassistant-backend \
  --restart always \
  --network "${NETWORK_NAME}" \
  --network-alias backend \
  --env-file salut_bot/.env \
  -e PYTHONUNBUFFERED=1 \
  -e DB_HOST=db \
  -v "${PROJECT_DIR}/maps:/app/maps" \
  ecoassistant-backend:latest

section "Starting telegram"
docker run -d \
  --name ecoassistant-telegram \
  --restart always \
  --network "${NETWORK_NAME}" \
  --env-file EcoBotProject/TelegramBot/.env \
  -e PYTHONUNBUFFERED=1 \
  --add-host host.docker.internal:host-gateway \
  -v "${PROJECT_DIR}/logs:/app/logs" \
  -v "${PROJECT_DIR}/data:/app/data" \
  ecoassistant-telegram:latest

section "Starting nginx on HTTP port 80 only"
docker run -d \
  --name ecoassistant-nginx \
  --restart always \
  --network "${NETWORK_NAME}" \
  --network-alias nginx \
  -p 80:80 \
  -v "${PROJECT_DIR}/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v /dev/null:/etc/nginx/conf.d/default.conf \
  -v "${PROJECT_DIR}/maps:/var/www/maps" \
  nginx:alpine

section "Result"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

section "Next checks"
echo "docker ps"
echo "docker logs --tail=100 ecoassistant-db"
echo "docker logs --tail=100 ecoassistant-backend"
echo "docker logs --tail=100 ecoassistant-telegram"
echo "docker logs --tail=100 ecoassistant-nginx"
echo "curl -I http://127.0.0.1"
EOF

chmod +x /home/ecoassistant/ecoassistant_deploy_scripts/scripts/05_up_project_manual.sh
bash -n /home/ecoassistant/ecoassistant_deploy_scripts/scripts/05_up_project_manual.sh && echo "05_up_project_manual syntax OK"