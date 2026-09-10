#!/usr/bin/env python3
"""Flux pre-flight (ADR 0048): every `${VAR}` a tree's build emits must have a binding, because Flux
substitutes an undefined variable with an empty string and fails open (`host: ""` is a catch-all router).
Every pod-template container must carry a cpu+memory request (#31, the scheduler spreads on requests).
A resource carrying `kustomize.toolkit.fluxcd.io/substitute: disabled` is exempt — that is how a
ConfigMap whose payload has its own `${…}` syntax (syslog-ng macros, JS template literals) is shipped.

usage: flux_check.py <repo root> [--build-only]   (reads kubernetes/flux/apps/*.yaml and the live cluster-bindings;
--build-only skips the binding check so a clone with no cluster — CI — still proves every tree builds)
"""
import re, subprocess, sys, json
import yaml

root = sys.argv[1]
TOKEN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")   # a token with a :-/:= default is bound by definition
build_only = "--build-only" in sys.argv[2:]
bindings = set()
if not build_only:
    kc = ["kubectl", "--kubeconfig", f"{root}/kubernetes/talos/.secrets/kubeconfig"]
    bindings = set(json.loads(subprocess.check_output(kc + ["-n", "flux-system", "get", "cm", "cluster-bindings", "-o", "json"]))["data"])
bad = 0
for app in sorted(__import__("glob").glob(f"{root}/kubernetes/flux/apps/*.yaml")):
    for ks in yaml.safe_load_all(open(app)):
        if not ks or ks.get("kind") != "Kustomization":
            continue
        pb = ks["spec"].get("postBuild", {})
        known = bindings | set(pb.get("substitute", {}))
        if not pb.get("substituteFrom"):
            known = set(pb.get("substitute", {}))
        path = f"{root}/{ks['spec']['path']}"
        docs = [d for d in yaml.safe_load_all(subprocess.check_output(["kubectl", "kustomize", path])) if d]
        for d in docs:
            spec = d.get("spec") or {}
            pod = ((spec.get("jobTemplate") or {}).get("spec") or spec).get("template", {}).get("spec") or {}
            for c in pod.get("containers", []) + pod.get("initContainers", []):
                if not ((c.get("resources") or {}).get("requests") or {}).keys() >= {"cpu", "memory"}:
                    bad += 1
                    print(f"{ks['metadata']['name']}: {d.get('kind')}/{d['metadata'].get('name')} container {c.get('name')} has no cpu+memory request (#31)")
        if build_only:
            print(f"{ks['metadata']['name']}: {len(docs)} resources")
            continue
        for d in docs:
            ann = (d.get("metadata") or {}).get("annotations") or {}
            lab = (d.get("metadata") or {}).get("labels") or {}
            if ann.get("kustomize.toolkit.fluxcd.io/substitute") == "disabled" or lab.get("kustomize.toolkit.fluxcd.io/substitute") == "disabled":
                continue
            missing = sorted({m.group(1) for m in TOKEN.finditer(yaml.safe_dump(d))} - known)
            if missing:
                bad += 1
                print(f"{ks['metadata']['name']}: {d.get('kind')}/{(d.get('metadata') or {}).get('name')} has no binding for: {' '.join(missing)}")
print("flux_check: OK" if not bad else f"flux_check: {bad} finding(s)", file=sys.stderr)
sys.exit(1 if bad else 0)
