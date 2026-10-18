# Stack 00: the kind cluster only. Node roles (labels/taints) are applied by
# stacks/10-nodes so they can change without recreating the cluster.
resource "kind_cluster" "this" {
  name            = var.cluster_name
  node_image      = var.kind_node_image
  kubeconfig_path = pathexpand(var.kubeconfig_path)
  wait_for_ready  = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
      extra_port_mappings {
        container_port = 30080
        host_port      = var.ingress_http_host_port
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 30443
        host_port      = var.ingress_https_host_port
        protocol       = "TCP"
      }
    }

    dynamic "node" {
      for_each = range(var.worker_count)
      content { role = "worker" }
    }
  }
}
