# Stack 10: node roles. Worker #1 hosts the Jenkins controller, the rest run
# agent pods. Both are tainted so nothing else lands on them; istiod and the
# Istio gateways go to the control-plane node (see 20-istio).
locals {
  workers         = local.cluster.worker_node_names
  controller_node = local.workers[0]
  agent_nodes     = slice(local.workers, 1, length(local.workers))

  roles = merge(
    { (local.controller_node) = "jenkins-controller" },
    { for n in local.agent_nodes : n => "jenkins-agent" },
  )
}

resource "kubernetes_labels" "role" {
  for_each    = local.roles
  api_version = "v1"
  kind        = "Node"
  metadata { name = each.key }
  labels = { role = each.value }
}

resource "kubernetes_node_taint" "role" {
  for_each = local.roles
  metadata { name = each.key }
  taint {
    key    = "role"
    value  = each.value
    effect = "NoSchedule"
  }
}
