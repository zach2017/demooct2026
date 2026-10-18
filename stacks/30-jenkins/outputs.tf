output "namespace" { value = local.namespace }
output "release_name" { value = helm_release.jenkins.name }
output "jenkins_url" { value = local.jenkins_url }
output "jenkins_admin_user" { value = var.jenkins_admin_user }
output "jenkins_admin_password" {
  value     = local.jenkins_admin_password
  sensitive = true
}
output "global_env_configmap" { value = kubernetes_config_map.global_env.metadata[0].name }
# The chart's config-reload sidecar picks up any ConfigMap carrying this label.
output "casc_configmap_label" { value = { "${helm_release.jenkins.name}-jenkins-config" = "true" } }
