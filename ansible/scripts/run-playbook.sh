#!/usr/bin/env bash
set -uo pipefail

umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/ansible-env.sh"

usage() {
  echo "사용법: $0 <operation> <playbook> [ansible-playbook arguments...]" >&2
}

if [ "$#" -lt 2 ]; then
  usage
  exit 64
fi

OPERATION="$1"
PLAYBOOK_INPUT="$2"
shift 2

if [[ ! "${OPERATION}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  echo "operation은 영문 소문자나 숫자로 시작하고 영문 소문자, 숫자, _, -만 사용할 수 있습니다." >&2
  exit 64
fi

cd "${HOMELAB_ANSIBLE_ROOT}"

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ansible-playbook 가 설치되어 있지 않습니다. 먼저 ./scripts/prepare-bastion.sh 를 실행하세요." >&2
  exit 127
fi

if [ ! -f "${PLAYBOOK_INPUT}" ]; then
  echo "Playbook을 찾을 수 없습니다: ${PLAYBOOK_INPUT}" >&2
  exit 66
fi

PLAYBOOK_DIR="$(cd -- "$(dirname -- "${PLAYBOOK_INPUT}")" && pwd -P)"
PLAYBOOK_PATH="${PLAYBOOK_DIR}/$(basename -- "${PLAYBOOK_INPUT}")"

case "${PLAYBOOK_PATH}" in
  "${HOMELAB_ANSIBLE_ROOT}"/*) ;;
  *)
    echo "Playbook은 ansible 프로젝트 내부에 있어야 합니다: ${PLAYBOOK_INPUT}" >&2
    exit 64
    ;;
esac

PLAYBOOK_RELATIVE="${PLAYBOOK_PATH#"${HOMELAB_ANSIBLE_ROOT}"/}"
RUNS_ROOT="${HOMELAB_RUNS_ROOT:-${HOMELAB_ANSIBLE_ROOT}/runs}"
RUN_ID="$(date '+%Y%m%d-%H%M%S')-$$"
RUN_DIR="${RUNS_ROOT}/${OPERATION}/${RUN_ID}"

while [ -e "${RUN_DIR}" ]; do
  RUN_ID="$(date '+%Y%m%d-%H%M%S')-$$-${RANDOM}"
  RUN_DIR="${RUNS_ROOT}/${OPERATION}/${RUN_ID}"
done

mkdir -p "${RUN_DIR}"
chmod 0700 "${RUN_DIR}"

METADATA_FILE="${RUN_DIR}/metadata.yml"
COMMAND_FILE="${RUN_DIR}/command.txt"
ANSIBLE_LOG_FILE="${RUN_DIR}/ansible.log"
STDOUT_FILE="${RUN_DIR}/stdout.log"
SUMMARY_FILE="${RUN_DIR}/summary.md"
START_EPOCH="$(date '+%s')"
STARTED_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
FINALIZED=false

yaml_quote() {
  local value="${1//\'/\'\'}"
  printf "'%s'" "${value}"
}

shell_quote() {
  printf '%q' "$1"
}

redact_extra_var() {
  local value="$1"
  local key

  if [[ "${value}" == @* ]]; then
    shell_quote "${value}"
    return
  fi

  if [[ "${value}" == *=* ]]; then
    key="${value%%=*}"
    case "${key}" in
      kubernetes_upgrade_confirm | kubernetes_upgrade_postcheck_only | \
        kubespray_force | argocd_force)
        shell_quote "${value}"
        ;;
      *)
        shell_quote "${key}=REDACTED"
        ;;
    esac
    return
  fi

  shell_quote "REDACTED"
}

write_command() {
  local expect_extra_var=false
  local expect_sensitive_option_value=false
  local argument

  {
    shell_quote "./scripts/run-playbook.sh"
    printf ' '
    shell_quote "${OPERATION}"
    printf ' '
    shell_quote "${PLAYBOOK_RELATIVE}"

    for argument in "$@"; do
      printf ' '

      if [ "${expect_extra_var}" = true ]; then
        redact_extra_var "${argument}"
        expect_extra_var=false
        continue
      fi

      if [ "${expect_sensitive_option_value}" = true ]; then
        shell_quote "REDACTED"
        expect_sensitive_option_value=false
        continue
      fi

      case "${argument}" in
        -e | --extra-vars)
          shell_quote "${argument}"
          expect_extra_var=true
          ;;
        --extra-vars=*)
          printf '%s=' "$(shell_quote "${argument%%=*}")"
          redact_extra_var "${argument#*=}"
          ;;
        -e?*)
          printf '%s' "$(shell_quote "-e")"
          redact_extra_var "${argument#-e}"
          ;;
        --vault-id | --vault-password-file | --vault-pass-file | \
          --private-key | --key-file | \
          --connection-password-file | --conn-pass-file | \
          --become-password-file | --become-pass-file)
          shell_quote "${argument}"
          expect_sensitive_option_value=true
          ;;
        --vault-id=* | --vault-password-file=* | --vault-pass-file=* | \
          --private-key=* | --key-file=* | \
          --connection-password-file=* | --conn-pass-file=* | \
          --become-password-file=* | --become-pass-file=*)
          shell_quote "${argument%%=*}=REDACTED"
          ;;
        *)
          shell_quote "${argument}"
          ;;
      esac
    done
    printf '\n'
  } > "${COMMAND_FILE}"

  chmod 0600 "${COMMAND_FILE}"
}

GIT_BRANCH="$(git branch --show-current 2>/dev/null || true)"
GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  GIT_DIRTY=true
else
  GIT_DIRTY=false
fi
ANSIBLE_VERSION="$(ansible-playbook --version 2>/dev/null | sed -n '1p')"
RUN_USER="$(id -un 2>/dev/null || true)"
RUN_HOST="$(hostname 2>/dev/null || true)"

write_metadata() {
  local status="$1"
  local exit_code="$2"
  local finished_at="$3"
  local duration="$4"
  local temporary_file="${RUN_DIR}/.metadata.yml.tmp"

  {
    printf 'run_id: %s\n' "$(yaml_quote "${RUN_ID}")"
    printf 'operation: %s\n' "$(yaml_quote "${OPERATION}")"
    printf 'started_at: %s\n' "$(yaml_quote "${STARTED_AT}")"
    printf 'finished_at: %s\n' "$(yaml_quote "${finished_at}")"
    printf 'duration_seconds: %s\n' "${duration}"
    printf 'user: %s\n' "$(yaml_quote "${RUN_USER}")"
    printf 'hostname: %s\n' "$(yaml_quote "${RUN_HOST}")"
    printf 'git:\n'
    printf '  branch: %s\n' "$(yaml_quote "${GIT_BRANCH}")"
    printf '  commit: %s\n' "$(yaml_quote "${GIT_COMMIT}")"
    printf '  dirty: %s\n' "${GIT_DIRTY}"
    printf 'ansible:\n'
    printf '  version: %s\n' "$(yaml_quote "${ANSIBLE_VERSION}")"
    printf 'inventory:\n'
    printf '  path: %s\n' "$(yaml_quote "inventories/homelab/hosts.yml")"
    printf 'playbook:\n'
    printf '  path: %s\n' "$(yaml_quote "${PLAYBOOK_RELATIVE}")"
    printf 'result:\n'
    printf '  status: %s\n' "$(yaml_quote "${status}")"
    printf '  exit_code: %s\n' "${exit_code}"
  } > "${temporary_file}"

  chmod 0600 "${temporary_file}"
  mv "${temporary_file}" "${METADATA_FILE}"
}

write_summary() {
  local status="$1"
  local exit_code="$2"
  local finished_at="$3"
  local duration="$4"

  {
    printf '# Ansible Execution\n\n'
    printf -- '- Operation: `%s`\n' "${OPERATION}"
    printf -- '- Run ID: `%s`\n' "${RUN_ID}"
    printf -- '- Playbook: `%s`\n' "${PLAYBOOK_RELATIVE}"
    printf -- '- Started: `%s`\n' "${STARTED_AT}"
    printf -- '- Finished: `%s`\n' "${finished_at}"
    printf -- '- Duration: `%s seconds`\n' "${duration}"
    printf -- '- Result: `%s`\n' "${status}"
    printf -- '- Exit code: `%s`\n\n' "${exit_code}"
    printf '## Git\n\n'
    printf -- '- Branch: `%s`\n' "${GIT_BRANCH}"
    printf -- '- Commit: `%s`\n' "${GIT_COMMIT}"
    printf -- '- Dirty: `%s`\n\n' "${GIT_DIRTY}"
    printf '## Ansible Recap\n\n```text\n'
    if [ -f "${STDOUT_FILE}" ]; then
      awk '/^PLAY RECAP/{capture=1} capture' "${STDOUT_FILE}"
    fi
    printf '```\n\n## Artifacts\n\n'
    printf -- '- `metadata.yml`\n'
    printf -- '- `command.txt`\n'
    printf -- '- `ansible.log`\n'
    printf -- '- `stdout.log`\n'
    printf -- '- `summary.md`\n'
  } > "${SUMMARY_FILE}"

  chmod 0600 "${SUMMARY_FILE}"
}

finalize() {
  local exit_code="$1"
  local status
  local finish_epoch
  local finished_at
  local duration

  if [ "${FINALIZED}" = true ]; then
    return
  fi
  FINALIZED=true

  finish_epoch="$(date '+%s')"
  finished_at="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  duration="$((finish_epoch - START_EPOCH))"

  case "${exit_code}" in
    0) status=success ;;
    130 | 143) status=interrupted ;;
    *) status=failure ;;
  esac

  write_metadata "${status}" "${exit_code}" "${finished_at}" "${duration}"
  write_summary "${status}" "${exit_code}" "${finished_at}" "${duration}"

  [ -f "${ANSIBLE_LOG_FILE}" ] || : > "${ANSIBLE_LOG_FILE}"
  [ -f "${STDOUT_FILE}" ] || : > "${STDOUT_FILE}"
  chmod 0600 "${ANSIBLE_LOG_FILE}" "${STDOUT_FILE}"

  echo "Execution artifact: ${RUN_DIR}"
}

trap 'exit 130' INT
trap 'exit 143' TERM
trap 'finalize "$?"' EXIT

write_command "$@"
write_metadata "running" "0" "" "0"

export ANSIBLE_LOG_PATH="${ANSIBLE_LOG_FILE}"

set +e
ansible-playbook "${PLAYBOOK_RELATIVE}" "$@" 2>&1 | tee "${STDOUT_FILE}"
ANSIBLE_EXIT_CODE="${PIPESTATUS[0]}"
set -e

exit "${ANSIBLE_EXIT_CODE}"
