# Destroy guard. `terraform destroy` on this stack first destroys this
# resource (it depends on everything else here, so it goes first in reverse
# order); its destroy-time provisioner runs scripts/guard-destroy.sh, which
# fails -- aborting the destroy before anything is touched -- when a later stack
# still holds state or the cluster still has objects that depend on this one.
# Bypass: FORCE_DESTROY=1 terraform destroy
resource "terraform_data" "destroy_guard" {
  input = {
    stack      = "30-jenkins"
    kubeconfig = local.cluster.kubeconfig_path
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${path.module}/../../scripts/guard-destroy.sh '${self.input.stack}' '${self.input.kubeconfig}'"
  }

  depends_on = [
    kubernetes_namespace.jenkins,
    kubernetes_config_map.global_env,
    kubernetes_secret.jenkins_admin,
    helm_release.jenkins,
    null_resource.wait_for_jenkins,
    kubectl_manifest.gateway,
    kubectl_manifest.virtualservice,
  ]
}
