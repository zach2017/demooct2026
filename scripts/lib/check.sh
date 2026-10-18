#!/usr/bin/env bash
# Shared helpers for stacks/*/check-deps.sh. Source this, then call the
# check_* functions; finish with check_summary (exits 1 if anything is missing).
#
# Output format:  [ OK ]      what            detail
#                 [MISSING]   what            how to get it
#                 [UNHEALTHY] what            kubectl describe <obj> follows
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE_DIR="$ROOT/state"
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/kind-jenkins.yaml}
MISSING=0; UNHEALTHY=0

_ok()   { printf '\033[32m[ OK ]\033[0m      %-32s %s\n' "$1" "${2:-}"; }
_miss() { printf '\033[31m[MISSING]\033[0m   %-32s %s\n' "$1" "${2:-}"; MISSING=$((MISSING+1)); }
_bad()  { printf '\033[33m[UNHEALTHY]\033[0m %-32s %s\n' "$1" "${2:-}"; UNHEALTHY=$((UNHEALTHY+1)); }
_describe() { echo "            ---- kubectl $* ----"; kubectl "$@" 2>&1 | sed -n '1,60p' | sed 's/^/            /'; echo; }

check_header() { printf '\n== %s: required dependencies (KUBECONFIG=%s)\n\n' "$1" "$KUBECONFIG"; }

# CLI tool on PATH
check_cli() {                 # name [install hint]
  if command -v "$1" >/dev/null 2>&1; then _ok "cli: $1" "$(command -v "$1")"
  else _miss "cli: $1" "${2:-install $1}"; fi
}

# Upstream stack state file with at least one managed resource
check_state() {               # stack
  local f="$STATE_DIR/$1.tfstate"
  if [ ! -f "$f" ]; then _miss "state: $1" "apply it first: make $1"; return; fi
  if python3 -c 'import json,sys; r=json.load(open(sys.argv[1])).get("resources",[]); sys.exit(0 if any(x.get("mode")=="managed" for x in r) else 1)' "$f"; then
    _ok "state: $1" "$f"
  else _miss "state: $1" "file exists but holds no resources: make $1"; fi
}

# Docker daemon
check_docker() {
  if docker info >/dev/null 2>&1; then
    _ok "docker daemon" "$(docker info --format '{{.NCPU}} cpu / {{.MemTotal}} bytes' 2>/dev/null)"
  else _miss "docker daemon" "start Docker Desktop"; fi
}

# kind cluster container(s)
check_kind_cluster() {        # name
  if kind get clusters 2>/dev/null | grep -qx "$1"; then
    local st; st=$(docker inspect -f '{{.State.Status}}' "$1-control-plane" 2>/dev/null)
    if [ "$st" = "running" ]; then _ok "kind cluster: $1" "control-plane container running"
    else _bad "kind cluster: $1" "control-plane container is '$st' (OOM? see docker ps -a --filter name=$1-)"; fi
  else _miss "kind cluster: $1" "make 00-cluster"; fi
}

# API server reachable
check_cluster_reachable() {
  if kubectl get --raw=/version >/dev/null 2>&1; then
    _ok "cluster reachable" "$(kubectl config current-context 2>/dev/null)"; return 0
  fi
  _miss "cluster reachable" "kubectl can't reach the API server; KUBECONFIG wrong or control-plane down"
  return 1
}

# Node with a label; also reports its Ready condition
check_node_label() {          # label-selector  description
  local nodes; nodes=$(kubectl get nodes -l "$1" -o name 2>/dev/null | sed 's|node/||')
  if [ -z "$nodes" ]; then _miss "node with $1" "$2"; return; fi
  for n in $nodes; do
    local ready; ready=$(kubectl get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "$ready" = "True" ]; then _ok "node $n ($1)" "Ready"
    else _bad "node $n ($1)" "not Ready"; _describe describe node "$n"; fi
  done
}

# Namespace
check_namespace() {           # ns  how-to-create
  if kubectl get ns "$1" >/dev/null 2>&1; then _ok "namespace: $1"
  else _miss "namespace: $1" "$2"; fi
}

# CRD installed
check_crd() {                 # crd-name  how-to-create
  if kubectl get crd "$1" >/dev/null 2>&1; then _ok "crd: $1"
  else _miss "crd: $1" "$2"; fi
}

# Generic object exists (kubectl get -n ns kind/name)
check_object() {              # ns  kind  name  how-to-create
  if kubectl get -n "$1" "$2" "$3" >/dev/null 2>&1; then _ok "$2/$3 (ns $1)"
  else _miss "$2/$3 (ns $1)" "$4"; fi
}

# Deployment/StatefulSet with all replicas ready; describes when not
check_workload() {            # ns  kind(deployment|statefulset)  name  how-to-create
  if ! kubectl get -n "$1" "$2" "$3" >/dev/null 2>&1; then _miss "$2/$3 (ns $1)" "$4"; return; fi
  local want have
  want=$(kubectl get -n "$1" "$2" "$3" -o jsonpath='{.spec.replicas}')
  have=$(kubectl get -n "$1" "$2" "$3" -o jsonpath='{.status.readyReplicas}'); have=${have:-0}
  if [ "$have" = "$want" ] && [ "$want" != "0" ]; then _ok "$2/$3 (ns $1)" "$have/$want ready"
  else
    _bad "$2/$3 (ns $1)" "$have/${want:-?} ready"
    _describe get pods -n "$1" -l "$(kubectl get -n "$1" "$2" "$3" -o jsonpath='{range .spec.selector.matchLabels}{end}' >/dev/null; kubectl get -n "$1" "$2" "$3" -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' | sed 's/,$//')"
    _describe describe "$2" -n "$1" "$3"
  fi
}

# Helm release deployed
check_helm_release() {        # ns  name  how-to-create
  if ! command -v helm >/dev/null 2>&1; then _miss "cli: helm" "install helm"; return; fi
  local st; st=$(helm -n "$1" status "$2" -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null)
  case "$st" in
    deployed) _ok "helm release: $1/$2" "deployed" ;;
    "")       _miss "helm release: $1/$2" "$3" ;;
    *)        _bad "helm release: $1/$2" "status=$st  (helm -n $1 history $2)" ;;
  esac
}

# Pod Ready by label; describes when not
check_pod_ready() {           # ns  label-selector  how-to-create
  local pod; pod=$(kubectl get pods -n "$1" -l "$2" -o name 2>/dev/null | head -1)
  if [ -z "$pod" ]; then _miss "pod $2 (ns $1)" "$3"; return; fi
  local ready; ready=$(kubectl get -n "$1" "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  if [ "$ready" = "True" ]; then _ok "$pod (ns $1)" "Ready"
  else _bad "$pod (ns $1)" "not Ready"; _describe describe -n "$1" "$pod"; fi
}

# Namespace label value
check_ns_label() {            # ns  key  expected  hint
  local v; v=$(kubectl get ns "$1" -o jsonpath="{.metadata.labels.$2}" 2>/dev/null)
  if [ "$v" = "$3" ]; then _ok "ns $1 label $2=$3"
  else _miss "ns $1 label $2=$3" "found '${v:-<none>}'; $4"; fi
}

# HTTP endpoint answers
check_http() {                # url  hint  [expected-code-regex]
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null)
  if echo "$code" | grep -Eq "${3:-^(200|302|403)$}"; then _ok "http $1" "HTTP $code"
  else _miss "http $1" "HTTP ${code:-000}; $2"; fi
}

check_summary() {
  echo
  if [ "$MISSING" -eq 0 ] && [ "$UNHEALTHY" -eq 0 ]; then echo "All dependencies present."; return 0; fi
  echo "$MISSING missing, $UNHEALTHY unhealthy. Resolve the items above before applying this stack."
  return 1
}


command -v _ok   >/dev/null 2>&1 || _ok()   { printf '  \033[32m✔\033[0m %s: %s\n' "$1" "$2"; }
command -v _bad  >/dev/null 2>&1 || _bad()  { printf '  \033[31m✘\033[0m %s: %s\n' "$1" "$2" >&2; }
command -v _miss >/dev/null 2>&1 || _miss() { printf '  \033[33m?\033[0m %s: %s\n' "$1" "$2" >&2; }


_pip_ensure() {
  local req=$1 py=${PYTHON:-python3}
  [ -f "$req" ] || { echo "requirements file not found: $req" >&2; return 1; }
  command -v "$py" >/dev/null 2>&1 || { echo "$py not found" >&2; return 1; }
 
  # Fast path: already satisfied?
  if "$py" -m pip --disable-pip-version-check check >/dev/null 2>&1 \
     && "$py" -c 'import yaml' >/dev/null 2>&1; then
    return 0
  fi
 
  local extra=()
  [ -z "${VIRTUAL_ENV:-}" ] && extra=(--user)
  if ! "$py" -m pip install -q --disable-pip-version-check "${extra[@]}" -r "$req" 2>/dev/null; then
    # PEP 668 managed environment → retry with the override.
    "$py" -m pip install -q --disable-pip-version-check "${extra[@]}" --break-system-packages -r "$req" \
      || { echo "pip install -r $req failed" >&2; return 1; }
  fi
}
 
# check_global_vars [ROOT]
#   ROOT defaults to $ROOT, then ".". Reports via _ok/_bad/_miss and returns
#   the validator's exit code (0 ok, 1 invalid, 2 missing/unparseable).
check_global_vars() {
  local root=${1:-${ROOT:-.}} py=${PYTHON:-python3}
  local here; here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  local validator=${VALIDATOR:-$here/validate_global_vars.py}
  local req=${REQUIREMENTS:-$here/requirements.txt}
  local label="jenkins/globalVars.yaml" out rc
 
  [ -f "$validator" ] || { _bad "$label" "validator not found: $validator"; return 2; }
 
  if ! out=$(_pip_ensure "$req" 2>&1); then
    _bad "$label" "could not install deps: ${out:-unknown error}"
    return 2
  fi
 
  out=$("$py" "$validator" --root "$root" 2>&1); rc=$?
  local first=${out%%$'\n'*} rest=${out#*$'\n'}
  case $rc in
    0) _ok   "$label" "${first#*: }" ;;                       # "N keys"
    2) if [[ $first == MISSING* ]]; then _miss "$label" "create it (see README: Global env vars)"
       else _bad "$label" "${first#*: }"; fi ;;               # parse error text
    *) _bad  "$label" "$(printf '%s' "${rest//  - /}" | paste -sd ';' | sed 's/;/; /g')" ;;
  esac
  return $rc
}
 
# Run directly (not sourced) → execute.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  check_global_vars "$@"
fi
 