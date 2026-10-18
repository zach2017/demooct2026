# Destroy guard. `terraform destroy` on this stack first destroys this
# resource (it depends on everything else here, so it goes first in reverse
# order); its destroy-time provisioner runs scripts/guard-destroy.sh, which
# fails -- aborting the destroy before anything is touched -- when a later stack
# still holds state or the cluster still has objects that depend on this one.
# Bypass: FORCE_DESTROY=1 terraform destroy
resource "terraform_data" "destroy_guard" {
  input = {
    stack      = "10-nodes"
    kubeconfig = local.cluster.kubeconfig_path
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${path.module}/../../scripts/guard-destroy.sh '${self.input.stack}' '${self.input.kubeconfig}'"
  }

  depends_on = [
    kubernetes_labels.role,
    kubernetes_node_taint.role,
  ]
}
