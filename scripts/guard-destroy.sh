#!/usr/bin/env bash
# Destroy guard. Invoked by each stack's terraform_data.destroy_guard
# (destroy-time provisioner) and by `make destroy`. Exits non-zero, with the
# blocking objects and the kubectl/terraform commands that show them, when
# something still depends on the stack being destroyed.
#
#   usage: guard-destroy.sh <stack-name> [kubeconfig]
#   bypass: FORCE_DESTROY=1
set -u
STACK=${1:?stack name, e.g. 20-istio}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KCFG=${2:-${KUBECONFIG:-$HOME/.kube/kind-jenkins.yaml}}
export KUBECONFIG="$KCFG"

if [ "${FORCE_DESTROY:-0}" = "1" ]; then
  echo "guard-destroy: FORCE_DESTROY=1, skipping checks for $STACK" >&2
  exit 0
fi

fail=0
red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
note() { printf '  %s\n' "$*" >&2; }

# ---- 1. downstream stacks still holding Terraform state ---------------------
state_has_resources() {           # $1 = stack dir name
  local f="$ROOT/state/$1.tfstate"
  [ -f "$f" ] && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])).get("resources",[]); sys.exit(0 if any(x.get("mode")=="managed" for x in r) else 1)' "$f"
}
check_downstream() {              # $@ = downstream stack dirs
  for d in "$@"; do
    if state_has_resources "$d"; then
      fail=1
      red "BLOCKED: stack $d still has resources in its state and depends on $STACK."
      note "see:    terraform -chdir=$ROOT/stacks/$d state list"
      note "fix:    terraform -chdir=$ROOT/stacks/$d destroy     (destroy downstream first)"
    fi
  done
}

# ---- 2. live cluster objects -------------------------------------------------
cluster_up() { kubectl get --raw=/version >/dev/null 2>&1; }
k() { kubectl "$@" 2>/dev/null; }

case "$STACK" in
  00-cluster)
    check_downstream 10-nodes 20-istio 30-jenkins 40-jenkins-jobs
    if cluster_up; then
      for ns in istio-system jenkins; do
        if k get ns "$ns" >/dev/null; then
          fail=1
          red "BLOCKED: namespace $ns still exists in the cluster (created by a later stack)."
          note "see:    kubectl get all -n $ns"
          note "fix:    destroy the stack that owns it, or: kubectl delete ns $ns"
        fi
      done
    fi
    ;;

  10-nodes)
    check_downstream 30-jenkins 40-jenkins-jobs
    if cluster_up; then
      for n in $(k get nodes -l role -o name | sed 's|node/||'); do
        pods=$(k get pods -A --field-selector spec.nodeName="$n" --no-headers | grep -v -E '^(kube-system|local-path-storage) ' | wc -l | tr -d ' ')
        if [ "$pods" -gt 0 ]; then
          fail=1
          red "BLOCKED: $pods workload pod(s) still scheduled on $n; removing its taint/label would strand them."
          note "see:    kubectl get pods -A --field-selector spec.nodeName=$n"
          note "fix:    terraform -chdir=$ROOT/stacks/30-jenkins destroy"
        fi
      done
    fi
    ;;

  20-istio)
    check_downstream 30-jenkins 40-jenkins-jobs
    if cluster_up; then
      inj=$(k get ns -l istio-injection=enabled -o name | sed 's|namespace/||' | tr '\n' ' ')
      if [ -n "$inj" ]; then
        fail=1
        red "BLOCKED: namespace(s) with istio-injection=enabled: $inj — their pods carry sidecars from istiod."
        note "see:    kubectl get ns -l istio-injection=enabled"
        note "see:    kubectl get pods -A -o jsonpath='{range .items[?(@.spec.initContainers[*].name==\"istio-proxy\")]}{.metadata.namespace}/{.metadata.name}{\"\\n\"}{end}'"
        note "fix:    terraform -chdir=$ROOT/stacks/30-jenkins destroy   (or label the ns istio-injection=disabled and restart pods)"
      fi
      gw=$(k get gateways.networking.istio.io,virtualservices.networking.istio.io -A --no-headers | grep -v '^istio-system ' | wc -l | tr -d ' ')
      if [ "$gw" -gt 0 ]; then
        fail=1
        red "BLOCKED: $gw Istio Gateway/VirtualService object(s) exist outside istio-system; removing the CRDs would orphan them."
        note "see:    kubectl get gateway,virtualservice -A"
        note "fix:    delete them (their owning stack) before destroying 20-istio"
      fi
    fi
    ;;

  30-jenkins)
    check_downstream 40-jenkins-jobs
    if cluster_up; then
      jobs=$(k get cm -n jenkins -l jenkins-jenkins-config=true -o name | grep -v -E 'configmap/jenkins-jenkins-(config|jcasc)' | sed 's|configmap/||' | tr '\n' ' ')
      if [ -n "$jobs" ]; then
        fail=1
        red "BLOCKED: job ConfigMaps from 40-jenkins-jobs still present: $jobs"
        note "see:    kubectl get cm -n jenkins -l jenkins-jenkins-config=true"
        note "fix:    terraform -chdir=$ROOT/stacks/40-jenkins-jobs destroy"
      fi
      agents=$(k get pods -n jenkins -l jenkins/label=jenkins-jenkins-agent --no-headers | wc -l | tr -d ' ')
      if [ "$agents" -gt 0 ]; then
        fail=1
        red "BLOCKED: $agents Jenkins build agent pod(s) running — builds are in progress."
        note "see:    kubectl get pods -n jenkins -l jenkins/label=jenkins-jenkins-agent"
        note "fix:    wait for builds to finish or abort them in the Jenkins UI"
      fi
    fi
    ;;

  40-jenkins-jobs)
    if cluster_up; then
      running=$(k get pods -n jenkins -l jenkins/label=jenkins-jenkins-agent --no-headers | wc -l | tr -d ' ')
      if [ "$running" -gt 0 ]; then
        fail=1
        red "BLOCKED: $running build(s) running; destroying the job definitions would strand them."
        note "see:    kubectl get pods -n jenkins -l jenkins/label=jenkins-jenkins-agent"
        note "fix:    let them finish or abort them in Jenkins"
      fi
    fi
    ;;
  single)
    # terraform/ (single root module): Terraform orders the teardown itself,
    # so the only thing worth refusing on is in-flight builds.
    if cluster_up; then
      running=$(k get pods -n jenkins -l jenkins/label=jenkins-jenkins-agent --no-headers | wc -l | tr -d ' ')
      if [ "$running" -gt 0 ]; then
        fail=1
        red "BLOCKED: $running build(s) running; destroying the platform would strand them."
        note "see:    kubectl get pods -n jenkins -l jenkins/label=jenkins-jenkins-agent"
        note "fix:    let them finish or abort them in Jenkins"
      fi
    fi
    ;;
  *) red "guard-destroy: unknown stack $STACK"; exit 2 ;;
esac

if [ "$fail" -ne 0 ]; then
  red "guard-destroy: refusing to destroy $STACK. Override with FORCE_DESTROY=1 if you really mean it."
  exit 1
fi
echo "guard-destroy: $STACK has no dependents, ok to destroy" >&2
