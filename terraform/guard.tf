# Destroy guard. In a single root module Terraform already destroys everything
# in reverse dependency order, so the cross-stack checks of stacks/*/guard.tf
# are unnecessary here. What remains worth refusing on is in-flight work:
# scripts/guard-destroy.sh's `single` case aborts the destroy while Jenkins
# build agent pods are running. Bypass: FORCE_DESTROY=1 terraform destroy
resource "terraform_data" "destroy_guard" {
  input = {
    stack      = "single"
    kubeconfig = kind_cluster.this.kubeconfig_path
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${path.module}/../scripts/guard-destroy.sh '${self.input.stack}' '${self.input.kubeconfig}'"
  }

  # Depends on the leaves of the graph so it is destroyed first.
  depends_on = [
    kubernetes_config_map.job,
    kubernetes_config_map.hello_src,
    kubernetes_config_map.agent_global_vars,
    kubectl_manifest.virtualservice,
    kubectl_manifest.egress_virtualservice,
    null_resource.wait_for_jenkins,
  ]
}
