#!/usr/bin/env bash
# Dependencies for 10-nodes: the kind cluster from 00-cluster, reachable, with its workers Ready.
source "$(dirname "$0")/../../scripts/lib/check.sh"
check_header 10-nodes
check_cli terraform; check_cli kubectl; check_cli python3
check_state 00-cluster
check_kind_cluster "${CLUSTER_NAME:-jenkins}"
if check_cluster_reachable; then
  workers=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | wc -l | tr -d ' ')
  if [ "$workers" -ge 2 ]; then _ok "worker nodes" "$workers (need >= 2: controller + agent)"
  else _miss "worker nodes" "found $workers; set worker_count >= 2 in 00-cluster (requires cluster rebuild)"; fi
  for n in $(kubectl get nodes -o name | sed 's|node/||'); do
    r=$(kubectl get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    [ "$r" = "True" ] && _ok "node $n" "Ready" || { _bad "node $n" "not Ready"; _describe describe node "$n"; }
  done
fi
check_summary
