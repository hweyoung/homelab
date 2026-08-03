# CloudNativePG operator

This directory contains values for the cluster-wide CloudNativePG operator. The operator is
owned by the `platform` AppProject and runs in `cnpg-system`; PostgreSQL `Cluster` resources
are owned separately by the `databases` AppProject under `gitops/databases/postgres`.

The root app deliberately uses a manual sync policy for both the operator and database
clusters. The repository currently provisions Kubernetes 1.30.4, while CloudNativePG 1.30.0
officially supports newer Kubernetes releases. Upgrade Kubernetes first, then sync in order:

1. verify `platform-local-path-provisioner` is healthy and `local-path` exists
2. `platform-cloudnative-pg`
3. wait for the operator deployment and CRDs to become ready
4. `databases-postgres-dev`
5. `databases-postgres-prod`

```bash
kubectl get storageclass local-path
kubectl get deployment -n cnpg-system
kubectl get crd clusters.postgresql.cnpg.io
kubectl get clusters.postgresql.cnpg.io -A
```
