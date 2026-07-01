#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

export HOMELAB_ANSIBLE_ROOT="${REPO_ROOT}"
export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"
export ANSIBLE_INVENTORY="${REPO_ROOT}/inventories/homelab/hosts.yml"
export ANSIBLE_ROLES_PATH="${REPO_ROOT}/roles"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/ansible-local}"
export TMPDIR="${TMPDIR:-/tmp}"

mkdir -p "${REPO_ROOT}/.ansible/tmp" "${ANSIBLE_LOCAL_TEMP}"

if [ -d "${REPO_ROOT}/.venv" ]; then
  # shellcheck disable=SC1091
  . "${REPO_ROOT}/.venv/bin/activate"
fi
