#!/usr/bin/env bash
# Dependencies for 20-istio: reachable cluster; control-plane node Ready (Istio
# runs there); no half-installed Istio from a previous attempt.
source "$(dirname "$0")/../../scripts/lib/check.sh"
check_header 20-istio
check_cli terraform; check_cli kubectl; check_cli helm "brew install helm"; check_cli python3
check_state 00-cluster
if check_cluster_reachable; then
  check_node_label "node-role.kubernetes.io/control-plane" "istiod and gateways are pinned to the control-plane node"
  # leftovers that would make helm_release creation fail
  if kubectl get ns istio-system >/dev/null 2>&1 && ! [ -f "$STATE_DIR/20-istio.tfstate" ]; then
    _bad "namespace istio-system" "exists but this stack has no state (orphan from an earlier install)"
    _describe get all -n istio-system
    echo "            fix: kubectl delete ns istio-system   (or import it: terraform import kubernetes_namespace.istio_system istio-system)"
  fi
  # outbound image pulls needed: istio/pilot, istio/proxyv2
  _ok "images" "istio/pilot, istio/proxyv2 will be pulled from docker.io"
fi
check_summary
