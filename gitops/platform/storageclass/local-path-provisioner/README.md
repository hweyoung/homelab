# Local Path Provisioner

Rancher Local Path Provisioner `v0.0.36` provides the cluster's single `local-path`
StorageClass. It dynamically creates node-local volumes under
`/opt/local-path-provisioner` on the node selected for the consuming Pod.

The local overlay changes two storage policies:

- marks `local-path` as the default StorageClass;
- uses `Retain` so deleting a PVC or CNPG Cluster does not immediately delete its PV data.

`WaitForFirstConsumer` is preserved so CNPG's `pool=dev` / `pool=prod` scheduling decision
happens before a volume is provisioned. This does not provide storage HA or enforce the
requested PVC capacity as a filesystem quota.

```bash
kubectl get deployment -n local-path-storage
kubectl get storageclass local-path
kubectl get pv,pvc -A
```

When a retained PV is no longer needed, inspect its node and backing directory before
manually deleting the PV and its data.
