#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_HOST=""
TARGET_PORT="22"
TARGET_USER="ecoassistant"
TARGET_NAME="dc1"
KEY_FILE="${HOME}/.ssh/ecoassistant_ansible_ed25519"
INVENTORY_FILE="inventory.ini"

usage() {
  cat <<USAGE
Usage:
  bash 00_bootstrap_ansible_access.sh --host HOST --port PORT --user USER

Example:
  bash 00_bootstrap_ansible_access.sh --host 172.30.64.1 --port 2223 --user ecoassistant
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      TARGET_HOST="$2"
      shift 2
      ;;
    --port)
      TARGET_PORT="$2"
      shift 2
      ;;
    --user)
      TARGET_USER="$2"
      shift 2
      ;;
    --name)
      TARGET_NAME="$2"
      shift 2
      ;;
    --key)
      KEY_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${TARGET_HOST}" ]]; then
  echo "[ERROR] --host is required" >&2
  usage
  exit 1
fi

echo "===== Configuration ====="
echo "Target host : ${TARGET_HOST}"
echo "Target port : ${TARGET_PORT}"
echo "Target user : ${TARGET_USER}"
echo "Target name : ${TARGET_NAME}"
echo "SSH key     : ${KEY_FILE}"
echo "Inventory   : ${INVENTORY_FILE}"

echo
echo "===== Checking required commands ====="
for cmd in ssh ssh-keygen; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[ERROR] Required command is missing: $cmd" >&2
    exit 1
  }
done
echo "[OK] Required commands are available."

echo
echo "===== Preparing SSH key ====="
mkdir -p "$(dirname "${KEY_FILE}")"
chmod 700 "$(dirname "${KEY_FILE}")"

if [[ ! -f "${KEY_FILE}" ]]; then
  ssh-keygen -t ed25519 -f "${KEY_FILE}" -N "" -C "ecoassistant-ansible@$(hostname)"
  chmod 600 "${KEY_FILE}"
  chmod 644 "${KEY_FILE}.pub"
  echo "[OK] SSH key generated: ${KEY_FILE}"
else
  echo "[OK] SSH key already exists: ${KEY_FILE}"
fi

echo
echo "===== Checking passwordless SSH ====="
if ssh \
  -i "${KEY_FILE}" \
  -p "${TARGET_PORT}" \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=accept-new \
  "${TARGET_USER}@${TARGET_HOST}" \
  "hostname" >/dev/null 2>&1; then
  echo "[OK] SSH key authentication already works."
else
  echo "[WARN] SSH key authentication is not configured yet."
  echo "[INFO] The password for ${TARGET_USER}@${TARGET_HOST} will be requested once."

  if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id \
      -i "${KEY_FILE}.pub" \
      -p "${TARGET_PORT}" \
      -o StrictHostKeyChecking=accept-new \
      "${TARGET_USER}@${TARGET_HOST}"
  else
    cat "${KEY_FILE}.pub" | ssh \
      -p "${TARGET_PORT}" \
      -o StrictHostKeyChecking=accept-new \
      "${TARGET_USER}@${TARGET_HOST}" \
      'umask 077;
       mkdir -p ~/.ssh;
       touch ~/.ssh/authorized_keys;
       cat >> ~/.ssh/authorized_keys;
       awk "!seen[\$0]++" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp;
       mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys;
       chmod 700 ~/.ssh;
       chmod 600 ~/.ssh/authorized_keys'
  fi
fi

echo
echo "===== Verifying SSH key authentication ====="
ssh \
  -i "${KEY_FILE}" \
  -p "${TARGET_PORT}" \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=accept-new \
  "${TARGET_USER}@${TARGET_HOST}" \
  "hostname"

echo "[OK] Passwordless SSH works."

echo
echo "===== Writing inventory.ini ====="
cat > "${INVENTORY_FILE}" <<INVENTORY_EOF
[new_servers]
${TARGET_NAME} ansible_host=${TARGET_HOST} ansible_port=${TARGET_PORT} ansible_user=${TARGET_USER} ansible_ssh_private_key_file=${KEY_FILE} ansible_python_interpreter=/usr/bin/python3
INVENTORY_EOF

cat "${INVENTORY_FILE}"

echo
echo "===== Testing Ansible raw connection ====="
ansible -i "${INVENTORY_FILE}" new_servers -m raw -a "hostname"

echo
echo "[OK] Bootstrap completed."
echo "Next command:"
echo "  ansible-playbook -i ${INVENTORY_FILE} deploy.yml"
