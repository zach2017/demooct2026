#!/usr/bin/env bash
# Dependencies for the single root module: host tooling, Docker, free host
# ports, the files it reads from the repo, and no overlapping deployment from
# the staged layout (same cluster name / kubeconfig).
source "$(dirname "$0")/../scripts/lib/check.sh"
check_header single
check_cli terraform "https://developer.hashicorp.com/terraform/install"
check_cli kind      "brew install kind"
check_cli kubectl   "brew install kubectl"
check_cli helm      "brew install helm"
check_cli docker    "install Docker Desktop"
check_cli python3   "used by the guard/check scripts"
check_docker

# Host ports the ingress gateway will be mapped to (skip if already deployed by us)
if ! [ -f "$STATE_DIR/single.tfstate" ]; then
  for p in 8085 8445; do
    if (command -v lsof >/dev/null && lsof -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1); then _bad "host port $p" "already in use: $(lsof -iTCP:$p -sTCP:LISTEN -Fc | sed -n 's/^c//p' | head -1)"; else _ok "host port $p" "free"; fi
  done
fi

# Files read at plan time
for f in jenkins/values.yaml.tftpl jenkins/jobs/hello.Jenkinsfile jenkins/globalVars.yaml src/Dockerfile src/hello.sh scripts/wait-for-jenkins.sh scripts/guard-destroy.sh; do
  if [ -f "$ROOT/$f" ]; then _ok "file: $f"; else _miss "file: $f" "part of the repo; restore it"; fi
done
check_global_vars "$ROOT"

# The staged layout and this module both create kind cluster "jenkins" at the
# same kubeconfig path; they cannot coexist.
for s in 00-cluster 10-nodes 20-istio 30-jenkins 40-jenkins-jobs; do
  f="$STATE_DIR/$s.tfstate"
  if [ -f "$f" ] && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])).get("resources",[]); sys.exit(0 if any(x.get("mode")=="managed" for x in r) else 1)' "$f"; then
    _bad "staged stack $s deployed" "state/$s.tfstate has resources; run 'make destroy' first, or set a different cluster_name/kubeconfig_path"
  fi
done
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME:-jenkins}" && ! [ -f "$STATE_DIR/single.tfstate" ]; then
  _bad "kind cluster: ${CLUSTER_NAME:-jenkins}" "exists but terraform/ has no state (orphan or staged deployment); kind delete cluster --name ${CLUSTER_NAME:-jenkins}"
fi
check_summary
