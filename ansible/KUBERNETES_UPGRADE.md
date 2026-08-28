# Kubernetes / Kubespray Upgrade Runbook

이 파일은 기존 경로 호환을 위해 유지한다. 최신 Kubernetes upgrade 절차는
[docs/kubernetes-upgrade.md](docs/kubernetes-upgrade.md)를 참고한다.

공식 실행 명령:

```bash
make kubernetes-upgrade-precheck
make kubernetes-upgrade
make kubernetes-upgrade-postcheck
```

신규 설치에는 upgrade workflow를 사용하지 않는다. `local-path` PV, single-node 역할,
PDB, backup과 복구 제약을 확인하지 않은 상태에서 upgrade를 실행하지 않는다.
