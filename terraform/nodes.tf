# ---------------------------------------------------------------------------
# Layer 10 -- node roles. Worker #1 hosts the Jenkins controller, the rest run
# agent pods. Both are tainted so nothing else lands on them; istiod and the
# Istio gateways go to the control-plane node (istio.tf). (stacks/10-nodes)
# ---------------------------------------------------------------------------
locals {
  controller_node = local.worker_node_names[0]
  agent_nodes     = slice(local.worker_node_names, 1, length(local.worker_node_names))

  roles = merge(
    { (local.controller_node) = "jenkins-controller" },
    { for n in local.agent_nodes : n => "jenkins-agent" },
  )

  controller_selector = { role = "jenkins-controller" }
  agent_selector      = { role = "jenkins-agent" }
}

resource "kubernetes_labels" "role" {
  for_each    = local.roles
  api_version = "v1"
  kind        = "Node"
  metadata { name = each.key }
  labels = { role = each.value }

  depends_on = [kind_cluster.this]
}

resource "kubernetes_node_taint" "role" {
  for_each = local.roles
  metadata { name = each.key }
  taint {
    key    = "role"
    value  = each.value
    effect = "NoSchedule"
  }

  depends_on = [kind_cluster.this]
}
