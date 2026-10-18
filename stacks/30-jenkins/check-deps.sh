#!/usr/bin/env bash
# Dependencies for 30-jenkins: node roles from 10-nodes, Istio CRDs + ingress
# gateway from 20-istio, storage class, and no stale Jenkins release.
source "$(dirname "$0")/../../scripts/lib/check.sh"
check_header 30-jenkins
check_cli terraform; check_cli kubectl; check_cli helm "brew install helm"; check_cli python3
check_state 00-cluster
check_state 10-nodes
check_state 20-istio
if check_cluster_reachable; then
  # 10-nodes
  check_node_label "role=jenkins-controller" "make 10-nodes (controller nodeSelector)"
  check_node_label "role=jenkins-agent"      "make 10-nodes (agent pod nodeSelector)"
  # 20-istio
  check_namespace istio-system "make 20-istio"
  check_crd gateways.networking.istio.io        "make 20-istio (istio-base CRDs)"
  check_crd virtualservices.networking.istio.io "make 20-istio (istio-base CRDs)"
  check_workload istio-system deployment istiod               "make 20-istio"
  check_workload istio-system deployment istio-ingressgateway "make 20-istio (ingress for the Jenkins Gateway)"
  if kubectl get mutatingwebhookconfiguration istio-sidecar-injector >/dev/null 2>&1; then _ok "sidecar injector webhook"
  else _miss "sidecar injector webhook" "make 20-istio (istiod installs istio-sidecar-injector)"; fi
  # storage for the controller PVC
  if kubectl get storageclass standard >/dev/null 2>&1; then _ok "storageclass standard" "kind local-path"
  else _miss "storageclass standard" "kind ships this by default; check kubectl get sc"; fi
  # leftover release / namespace without state
  if ! [ -f "$STATE_DIR/30-jenkins.tfstate" ]; then
    if kubectl get ns jenkins >/dev/null 2>&1; then
      _bad "namespace jenkins" "exists but this stack has no state (orphan)"; _describe get all -n jenkins
      echo "            fix: helm -n jenkins uninstall jenkins; kubectl delete ns jenkins"
    fi
  else
    st=$(helm -n jenkins status jenkins -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null)
    if [ -n "$st" ] && [ "$st" != "deployed" ]; then _bad "helm release jenkins/jenkins" "status=$st; helm -n jenkins uninstall jenkins before re-applying"; fi
  fi
fi
check_summary
