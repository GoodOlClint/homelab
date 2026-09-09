#!/bin/bash
# Cluster half of `make update`. Restarts only the workloads whose image tag is :latest —
# those carry imagePullPolicy Always, so recreating the pod re-pulls through Zot, which
# re-checks the tag upstream. Chart images are version-pinned with IfNotPresent and a
# restart cannot move them: those roll by bumping the chart and re-running its deploy
# target, deliberately (ADR 0016). Re-running a deploy target does NOT update an image —
# with no pod-template change there is no new ReplicaSet and no pull.
#   NS=<namespace>   restrict to one namespace
source "$(dirname "$0")/lib.sh"

targets=$(kubectl get deploy,statefulset -A -o json | python3 -c '
import json,sys,os
want=os.environ.get("NS","")
for d in json.load(sys.stdin)["items"]:
    ns=d["metadata"]["namespace"]
    if want and ns!=want: continue
    cs=d["spec"]["template"]["spec"]["containers"]
    if any(c["image"].rsplit("/",1)[-1].endswith(":latest") for c in cs):
        print(ns, d["kind"].lower()+"/"+d["metadata"]["name"])
')
[ -n "$targets" ] || { echo "nothing on :latest${NS:+ in $NS}"; exit 0; }

echo "$targets" | sed 's/^/  /'
echo "$targets" | while read -r ns obj; do kubectl -n "$ns" rollout restart "$obj" >/dev/null; done
echo "$targets" | while read -r ns obj; do
  kubectl -n "$ns" rollout status "$obj" --timeout=600s || echo "  !! $ns $obj did not settle"
done
