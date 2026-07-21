#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/ansible-env.sh"

cd "${HOMELAB_ANSIBLE_ROOT}"

if ! command -v ansible-vault >/dev/null 2>&1; then
  echo "ansible-vault 가 설치되어 있지 않습니다. 먼저 ./scripts/prepare-bastion.sh 를 실행하세요." >&2
  exit 127
fi

# vault 작업 대상 기본값. 이 저장소에서 vault 로 다루는 파일은 secrets.yml 뿐입니다.
SECRETS_FILE="${HOMELAB_SECRETS_FILE:-secrets.yml}"

# 인자 없이 호출하면 secrets.yml 을 편집한다.
#   ./scripts/run-vault.sh            →  ansible-vault edit secrets.yml
if [ "$#" -eq 0 ]; then
  set -- edit "${SECRETS_FILE}"
fi

# 서브커맨드만 주고 파일을 생략하면 secrets.yml 을 대상으로 붙인다.
#   ./scripts/run-vault.sh view       →  ansible-vault view secrets.yml
#   ./scripts/run-vault.sh encrypt    →  ansible-vault encrypt secrets.yml
# 파일을 명시하면(예: view path/to/other.yml) 그대로 전달된다.
if [ "$#" -eq 1 ]; then
  case "$1" in
    edit | view | encrypt | decrypt | rekey | create)
      set -- "$1" "${SECRETS_FILE}"
      ;;
  esac
fi

exec ansible-vault "$@"
