#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/ansible-env.sh"

cd "${HOMELAB_ANSIBLE_ROOT}"

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ansible-playbook 가 설치되어 있지 않습니다. 먼저 ./scripts/prepare-bastion.sh 를 실행하세요." >&2
  exit 127
fi

exec ansible-playbook "$@"
