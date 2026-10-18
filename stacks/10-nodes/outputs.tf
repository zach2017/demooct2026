output "controller_node" { value = local.controller_node }
output "agent_nodes" { value = local.agent_nodes }
output "controller_selector" { value = { role = "jenkins-controller" } }
output "agent_selector" { value = { role = "jenkins-agent" } }
