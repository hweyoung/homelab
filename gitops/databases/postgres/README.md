# PostgreSQL on CloudNativePG

The shared base defines a single-instance PostgreSQL 18 cluster. The dev/prod overlays keep
data in separate namespaces and pin each cluster to its dedicated worker pool.
The `platform-local-path-provisioner` Application must be healthy before these clusters are
synced.

| environment | namespace | cluster/service | node selector | storage |
| --- | --- | --- | --- | --- |
| dev | `postgres-dev` | `postgres-dev` / `postgres-dev-rw` | `pool=dev` | `local-path`, 10Gi |
| prod | `postgres-prod` | `postgres-prod` / `postgres-prod-rw` | `pool=prod` | `local-path`, 50Gi |

CNPG creates the application credential Secret automatically (`postgres-dev-app` or
`postgres-prod-app`). Applications should use the `-rw` Service and the generated app Secret,
not a specific PostgreSQL Pod. Superuser network access is disabled.

This is intentionally not an HA layout: each environment currently has only one worker and
`local-path` volumes are node-local. Backups must be configured before treating prod data as
recoverable.

```bash
kustomize build overlays/dev
kustomize build overlays/prod
kubectl get cluster -n postgres-dev
kubectl get cluster -n postgres-prod
```
