#!/usr/bin/env bash
set -euo pipefail

if ! command -v dnf >/dev/null 2>&1; then
  echo "이 스크립트는 dnf 가 있는 Rocky/RHEL 계열 bastion 을 가정합니다." >&2
  exit 1
fi

sudo dnf install -y curl gcc git libffi-devel make openssh-clients openssl-devel \
  python3 python3-devel python3-libselinux python3-pip rsync tar unzip vim

PYTHON_BIN=""
for candidate in python3.12 python3.11; do
  if sudo dnf install -y "${candidate}" "${candidate}-devel" "${candidate}-pip"; then
    PYTHON_BIN="${candidate}"
    break
  fi
done

if [ -z "${PYTHON_BIN}" ]; then
  PYTHON_BIN="python3"
fi

"${PYTHON_BIN}" - <<'PY'
import sys

if sys.version_info < (3, 11):
    raise SystemExit(
        "Kubespray pinned Ansible 버전은 컨트롤러에 Python 3.11+ 가 필요합니다. "
        "infra-bastion 에 python3.11 또는 python3.12 를 설치한 뒤 다시 실행하세요."
    )
PY

"${PYTHON_BIN}" -m venv .venv
. .venv/bin/activate

python -m pip install --upgrade pip setuptools wheel
python -m pip install -r requirements-controller.txt

ansible --version

./scripts/sync-kubespray.sh

python -m pip install -r kubespray/requirements.txt

# shellcheck disable=SC1091
. scripts/ansible-env.sh

./scripts/run-inventory.sh --graph
