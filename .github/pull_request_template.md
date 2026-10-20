<!--
PR 제목: `type(area): 변경 요약`
  type: feat · fix · refactor · docs · chore · ci
  area: infra · cluster · gitops · network · data · secrets · delivery · observability · docs
  예) feat(secrets): add ExternalSecret for api-common dev
      fix(cluster): honor node taints in Traefik topology spread
브랜치: `feat/<이슈번호>-<slug>` (예: `feat/208-kargo-dev-warehouse`)
같은 Task로 PR을 여러 번 올릴 때도 제목은 변경 내용에 맞게 다르게 작성합니다.
-->

## 🔗 관련 이슈
Closes #

## 📋 변경 내용
- 

## 🔍 검증
<!-- 실행한 명령과 결과 (helm template, kustomize build, ansible --syntax-check, kubectl 확인 등) -->
```bash

```

## ⚠️ 영향 범위 · 롤백
<!-- dev/prod 영향, Secret·DB·CRD 변경 여부, 되돌리는 방법 -->
- 영향:
- 롤백:

## ✅ 체크리스트
- [ ] 평문 Secret·토큰이 포함되지 않았습니다 (`*.sops.yaml` 암호화 확인)
- [ ] `GitOps Validate` 워크플로가 통과합니다
- [ ] prod 변경은 dev에서 먼저 확인했습니다 (해당 시)
- [ ] 관련 문서(README · runbook)를 함께 수정했습니다 (해당 시)
