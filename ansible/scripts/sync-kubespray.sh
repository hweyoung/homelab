#!/usr/bin/env bash
set -euo pipefail

KUBESPRAY_VERSION="${KUBESPRAY_VERSION:-$(sed -n 's/^kubespray_version: *"\([^"]*\)".*/\1/p' inventories/homelab/group_vars/all.yml)}"

if [ -z "${KUBESPRAY_VERSION}" ]; then
  echo "inventories/homelab/group_vars/all.yml 에 kubespray_version 이 설정되지 않았습니다." >&2
  exit 1
fi

if [ ! -f kubespray/cluster.yml ]; then
  git clone --branch "${KUBESPRAY_VERSION}" https://github.com/kubernetes-sigs/kubespray.git kubespray
else
  git -C kubespray fetch --tags
  git -C kubespray checkout "${KUBESPRAY_VERSION}"
fi

if [ -x .venv/bin/python ]; then
  if [ ! -x .kubespray-venv/bin/python ]; then
    .venv/bin/python -m venv .kubespray-venv
  fi
  .kubespray-venv/bin/python -m pip install --upgrade pip setuptools wheel
  .kubespray-venv/bin/python -m pip install -r kubespray/requirements.txt
else
  echo "WARNING: .venv가 없어 .kubespray-venv 준비를 건너뜁니다." >&2
  echo "먼저 ./scripts/prepare-bastion.sh를 실행하세요." >&2
fi

echo "Kubespray checkout 은 ${KUBESPRAY_VERSION} 에 고정되어 있습니다."
