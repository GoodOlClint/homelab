# Static viewer

A shared, private static-file viewer on the Talos cluster. Top-level folders belong to projects (`/us-law/` first; first content `/us-law/us-law-ar/2021R/`). Files live on a Synology share and nginx serves them read-only. Projects deploy by `rsync` to the NAS, so adding content never touches the cluster.

## URL and access

`https://viewer.<service domain>/<project>/…`, one Flux tree (`kubernetes/static-viewer/`, namespace `static-viewer`).

- Reachable from the LAN and the mobile WireGuard VLAN only. There is no public DNS record (ADR 0044 mode `none`); external-dns publishes the Ingress host into BIND only.
- Behind authentik forward-auth, so only `authentik Admins` get in.
- Never indexed: every response carries `X-Robots-Tag: noindex, nofollow, noarchive`, `/robots.txt` disallows everything, and `autoindex` is off (a folder with no `index.html` is a 404, not a listing).
- The probe path `/healthz` answers 200 for the readiness and liveness probes and for the Uptime Kuma row, which uses in-cluster service DNS because the forward-auth 302 would break a probe of the public host.

## Deploy a project

```
/opt/homebrew/bin/rsync -a --delete --delay-updates --chmod=D755,F644 \
  -e "ssh -o IdentitiesOnly=yes -i ~/.ssh/viewer-<project>" \
  <out>/ <project>-deploy@<nas>:/volume1/static-viewer/<project>/<path>/
```

- Use GNU rsync from Homebrew. macOS `openrsync` fails against DSM with `unexpected end of file`.
- A non-admin DSM user has no shell, so a bare `ssh` printing `Permission denied` after key auth is normal. Test with the rsync command.
- The user's home directory and `.ssh` must carry no DSM ACL. `chmod 755 ~`, `chmod 700 ~/.ssh`, `chmod 600 ~/.ssh/authorized_keys` clears it. With an ACL present sshd StrictModes silently rejects the key.

## Add a project

A folder under `/volume1/static-viewer/<project>/` and a DSM user named `<project>-deploy` (first: `us-law-deploy`) with write access to that folder only. No cluster change.

## Operator hand steps (DSM and NFS)

Proven end to end 2026-10-14 (an rsync dry run from the Mac passed).

- The share is `static-viewer` (path `/volume1/static-viewer`), one top-level folder per project. The deploy user is `<project>-deploy`, a member of `users` only, with the application privilege **rsync** only.
- Share-level permission: the deploy user gets Read/Write. That setting is only the ceiling; the folder ACLs below do the real narrowing.
- Share root ACL entry: `user:<project>-deploy:allow:r-x---a-R-c--:---n` (read and traverse, this folder only). DSM's File Station → Permission UI produces it.
- Project folder ACL entry: `sudo synoacltool -add /volume1/static-viewer/<project> "user:<project>-deploy:allow:rwxpdDaARWc--:fd--"`. Without it rsync fails with `change_dir … Permission denied (13)`.
- SSH key: enable the user home service, then put the key in `/volume1/homes/<project>-deploy/.ssh/authorized_keys`. `chmod 755` the home folder, `700` on `.ssh`, `600` on the key file. The `chmod` clears DSM's ACL, which sshd StrictModes otherwise rejects silently; `synoacltool -del` errors and is not needed. A bare `ssh` login then prints `Permission denied` because the user has no shell; that is a pass.
- Client: `/opt/homebrew/bin/rsync`. macOS's openrsync fails with `unexpected end of file`.
- NFS export rule on the share: read-only, copied from the `docker` share's rule, with "Allow users to access mounted subfolders" on.

## Cluster objects

- `pv.yaml`: PV `static-viewer` (ReadOnlyMany, `Retain`) and its PVC, server from the `SYNOLOGY_STORAGE` binding.
- `app.yaml`: one nginx-unprivileged replica (`Recreate`, non-root, requests only) mounting the PVC read-only at `/usr/share/nginx/html`, a Service on 8080 and the forward-auth Ingress.
- `default.conf` rides a `configMapGenerator` (a change rolls the pod) with Flux substitution disabled, because nginx `$uri` is not a Flux variable.
- The namespace and the Flux ServiceAccount come from `make k8s-seed` (`k8s_seed_namespaces`, `k8s_seed_pv_trees`). A push to `main` is the deploy.
