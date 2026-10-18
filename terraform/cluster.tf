# ---------------------------------------------------------------------------
# Layer 00 -- kind cluster: control-plane + N plain workers, host-port maps for
# the Istio ingress gateway. (stacks/00-cluster/main.tf)
# ---------------------------------------------------------------------------
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

locals {
  # kind names workers <cluster>-worker, <cluster>-worker2, <cluster>-worker3 ...
  worker_node_names = [for i in range(var.worker_count) : i == 0 ? "${var.cluster_name}-worker" : "${var.cluster_name}-worker${i + 1}"]
}
