# Ceph RBD volumes: Retain, and how to rebind an image to a new claim

Every `ceph-rbd` PersistentVolume carries `persistentVolumeReclaimPolicy: Retain` (StorageClass default since 2026-09-10, existing PVs patched by `make talos-csi`; ADR 0048 WP4). Deleting a PVC, or Flux pruning one, leaves the PV `Released` and the Ceph image intact. Deleting the PV object also leaves the image. Only `rbd rm` on a node destroys data.

Rehearsed 2026-09-10: a file written through a dynamic claim, the claim and the PV object deleted, the image rebound through a static PV on the same cluster, the file read back byte-identical. The same procedure is the restore lane for a cluster rebuilt from zero.

## Find the image

From a live or `Released` PV: `kubectl get pv <pv> -o jsonpath='{.spec.csi.volumeAttributes.imageName}'` — `csi-vol-<uuid>`.

With the cluster gone: on a PVE node, `rbd ls ceph-rbd | grep csi-vol` lists every image; `rbd info ceph-rbd/<image>` gives the size. Match images to workloads by the PBS-side record of `kubectl get pv -o custom-columns=NAME:.metadata.name,IMAGE:.spec.csi.volumeAttributes.imageName,CLAIM:.spec.claimRef.namespace/.spec.claimRef.name` — capture that listing into the Ansible seed play's output (WP5) so it exists outside the cluster.

## Rebind

A static PV names the image directly (`volumeHandle` = the image name, `staticVolume: "true"`), pre-binds to the claim with `claimRef`, and the claim pins the PV with `volumeName`. Sizes must match the image.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata: {name: <workload>-restored}
spec:
  accessModes: [ReadWriteOnce]
  capacity: {storage: <image size>}
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ceph-rbd
  volumeMode: Filesystem
  claimRef: {namespace: <ns>, name: <pvc name the workload mounts>}
  csi:
    driver: rbd.csi.ceph.com
    fsType: ext4
    volumeHandle: csi-vol-<uuid>
    nodeStageSecretRef: {name: csi-rbd-secret, namespace: ceph-csi}
    volumeAttributes: {clusterID: "<ceph fsid>", pool: ceph-rbd, staticVolume: "true", imageFeatures: layering}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: <pvc name>, namespace: <ns>}
spec: {accessModes: [ReadWriteOnce], storageClassName: ceph-rbd, volumeName: <workload>-restored, resources: {requests: {storage: <image size>}}}
```

`clusterID` is the fsid the StorageClass carries (`kubectl get sc ceph-rbd -o jsonpath='{.parameters.clusterID}'`, or `ceph fsid` on a node). Apply the PV and PVC before the workload's Deployment; the claim binds immediately (`kubectl -n <ns> wait --for=jsonpath='{.status.phase}'=Bound pvc/<name>`).

Static volumes cannot be expanded or snapshotted through CSI. To get back to a dynamic volume, create a fresh dynamic PVC and copy the data with a pod that mounts both.

## Retire an image on purpose

`Retain` means a retired workload's image stays until someone removes it. After the PVC and PV are gone: `rbd rm ceph-rbd/csi-vol-<uuid>` on a node. Check `rbd status ceph-rbd/<image>` shows no watchers first.

## Gotchas

- `kubectl delete pv` on a PV whose claim still exists blocks forever on the `kubernetes.io/pv-protection` finalizer with no message; delete the claim first.
- `kubectl delete pod X pvc Y` deletes two pods named X and Y; resource types are per argument (`pod/X pvc/Y`).
- A `Released` PV cannot be rebound in place (its `claimRef` still names the old claim's UID); delete the PV object and create the static one.
