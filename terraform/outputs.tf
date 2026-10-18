# Union of stacks/*/outputs.tf. `make single-output` reads kubeconfig_path,
# jenkins_url and jenkins_admin_password, the same names the stacks export.

# --- cluster ------------------------------------------------------------------
output "cluster_name" { value = kind_cluster.this.name }
output "kubeconfig_path" { value = kind_cluster.this.kubeconfig_path }
output "endpoint" { value = kind_cluster.this.endpoint }
output "ingress_http_host_port" { value = var.ingress_http_host_port }
output "worker_node_names" { value = local.worker_node_names }

# --- nodes --------------------------------------------------------------------
output "controller_node" { value = local.controller_node }
output "agent_nodes" { value = local.agent_nodes }
output "controller_selector" { value = local.controller_selector }
output "agent_selector" { value = local.agent_selector }

# --- istio --------------------------------------------------------------------
output "istio_namespace" { value = kubernetes_namespace.istio_system.metadata[0].name }
output "ingress_gateway_selector" { value = local.ingress_gateway_selector }
output "egress_hosts" { value = var.egress_hosts }
output "istiod_release" { value = helm_release.istiod.name }

# --- jenkins ------------------------------------------------------------------
output "namespace" { value = local.namespace }
output "release_name" { value = helm_release.jenkins.name }
output "jenkins_url" { value = local.jenkins_url }
output "jenkins_admin_user" { value = var.jenkins_admin_user }
output "jenkins_admin_password" {
  value     = local.jenkins_admin_password
  sensitive = true
}
output "global_env_configmap" { value = kubernetes_config_map.global_env.metadata[0].name }
output "casc_configmap_label" { value = local.casc_configmap_label }

# --- jobs ---------------------------------------------------------------------
output "jobs" { value = keys(local.jobs) }
output "agent_global_vars" {
  description = "Keys injected into every agent pod from jenkins/globalVars.yaml"
  value       = keys(local.global_vars)
}
