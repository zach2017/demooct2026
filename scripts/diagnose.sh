#!/usr/bin/env bash
# One-shot snapshot of everything relevant to a stuck Jenkins install.
#   usage: KUBECONFIG=~/.kube/kind-jenkins.yaml scripts/diagnose.sh > diagnose.txt
set +e
h(){ echo; echo "===== $*"; }
h nodes;              kubectl get nodes -o wide --show-labels
h istio-system pods;  kubectl -n istio-system get pods -o wide
h jenkins objects;    kubectl -n jenkins get all,pvc,cm,secret
h jenkins-0 describe; kubectl -n jenkins describe pod jenkins-0
h jenkins events;     kubectl -n jenkins get events --sort-by=.lastTimestamp | tail -30
for c in istio-init istio-proxy init jenkins config-reload; do
  h "logs: $c"; kubectl -n jenkins logs jenkins-0 -c "$c" --tail=100
done
h helm;               helm -n jenkins status jenkins; helm -n jenkins history jenkins
h istio routing;      kubectl get gateway,virtualservice,serviceentry -A
