# 문서

홈랩 프로젝트의 운영·설계 문서를 모아 둔 곳이다. 전체 개요는 [루트 README](../README.md)에서
시작한다. 컴포넌트별 설정 메모는 매니페스트 옆 README에 두고 아래에서 링크한다.
`*/issues/`는 작업 당시의 설계 기록이며 현재 상태의 기준이 아니다.

## Terraform

- [Terraform 운영](terraform/README.md) — Proxmox VM 프로비저닝

## Ansible / Kubespray

- [Ansible 운영](ansible/README.md) — 진입점, Make target, 실행 정책
- [아키텍처](ansible/architecture.md)
- [실행 방식](ansible/execution.md)
- [Kubernetes 설치](ansible/kubernetes-install.md)
- [Kubernetes 업그레이드](ansible/kubernetes-upgrade.md)
- [Helm CLI 업그레이드](ansible/helm-upgrade.md)
- [Argo CD 업그레이드](ansible/argocd-upgrade.md)
- [트러블슈팅](ansible/troubleshooting.md)
- [스크립트 책임](../ansible/scripts/README.md)

## GitOps / Argo CD

- [GitOps 운영](gitops/README.md) — 구조, Application 변경 절차, 검증
- [GitOps 아키텍처](gitops/architecture.md) — sync wave, 권한, 트래픽, 운영 한계
- [GitOps 검증 (CI)](gitops/validation.md)
- [Secret 관리](gitops/secrets.md) — SOPS/KSOPS, bootstrap Secret 회전
- [OpenBao + ESO](gitops/openbao-eso.md)
- [플랫폼 업그레이드](gitops/platform-upgrade.md) — `platformVersions` 단계별 업그레이드
- [Observability](gitops/observability.md) — Prometheus, Grafana, Loki, Alloy, 알림 rule, 대시보드

### 컴포넌트 README

| 영역 | 문서 |
| --- | --- |
| AppProject 권한 | [argocd-control-plane](../gitops/clusters/homelab/argocd-control-plane/README.md) |
| Gateway | [gateway](../gitops/platform/gateway/README.md) |
| Storage | [local-path-provisioner](../gitops/platform/storageclass/local-path-provisioner/README.md) |
| DB operator | [cloudnative-pg](../gitops/platform/cloudnative-pg/README.md) |
| PostgreSQL | [postgres](../gitops/databases/postgres/README.md) |
| Object storage | [garage](../gitops/platform/garage/README.md) |
| 이미지 승격 | [kargo](../gitops/platform/kargo/README.md) |
| Monitoring | [monitoring](../gitops/platform/monitoring/README.md) |
| 애플리케이션 | [api-common](../gitops/apps/api-common/README.md) |
