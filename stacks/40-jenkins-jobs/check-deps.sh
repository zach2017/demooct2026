#!/usr/bin/env bash
# Dependencies for 40-jenkins-jobs: a Ready Jenkins controller from 30-jenkins
# with the config-reload sidecar, the global-env ConfigMap, and the Job DSL +
# JCasC plugins it needs to turn these ConfigMaps into jobs.
source "$(dirname "$0")/../../scripts/lib/check.sh"
check_header 40-jenkins-jobs
check_cli terraform; check_cli kubectl; check_cli python3
check_state 00-cluster
check_state 30-jenkins
if check_cluster_reachable; then
  check_namespace jenkins "make 30-jenkins"
  check_helm_release jenkins jenkins "make 30-jenkins"
  check_pod_ready jenkins "app.kubernetes.io/component=jenkins-controller" "make 30-jenkins"
  check_object jenkins configmap jenkins-global-env "make 30-jenkins"
  # config-reload sidecar present in the controller pod
  pod=$(kubectl get pods -n jenkins -l app.kubernetes.io/component=jenkins-controller -o name 2>/dev/null | head -1)
  if [ -n "$pod" ]; then
    if kubectl get -n jenkins "$pod" -o jsonpath='{.spec.containers[*].name}' | grep -qw config-reload; then
      _ok "config-reload sidecar" "jobs ConfigMaps will be hot-reloaded"
    else _miss "config-reload sidecar" "controller.sidecars.configAutoReload.enabled must be true in jenkins/values.yaml.tftpl"; fi
    # required plugins
    for p in job-dsl configuration-as-code workflow-aggregator kubernetes; do
      if kubectl exec -n jenkins "$pod" -c jenkins -- test -e "/var/jenkins_home/plugins/$p.jpi" 2>/dev/null \
      || kubectl exec -n jenkins "$pod" -c jenkins -- test -e "/var/jenkins_home/plugins/$p.hpi" 2>/dev/null; then
        _ok "plugin: $p"
      else _miss "plugin: $p" "add to controller.installPlugins in jenkins/values.yaml.tftpl and make 30-jenkins"; fi
    done
  fi
  # agent pod template must reference jenkins-agent-global-vars (30-jenkins values)
  if kubectl -n jenkins get cm jenkins-jenkins-jcasc-config -o jsonpath='{.data}' 2>/dev/null | grep -q jenkins-agent-global-vars; then
    _ok "agent template envFrom" "jenkins-agent-global-vars referenced"
  else _miss "agent template envFrom" "30-jenkins values are older than this stack: make 30-jenkins"; fi
  echo "$ROOT/jenkins/globalVars.yaml"
  check_global_vars "$ROOT"
  check_http "http://localhost:${INGRESS_PORT:-8080}/login" "ingress Gateway/VirtualService from 30-jenkins or Jenkins not Ready"
  # agent nodes for the builds these jobs will run
  check_node_label "role=jenkins-agent" "make 10-nodes"
fi
check_summary
