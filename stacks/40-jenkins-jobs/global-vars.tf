# Agent-wide global env from jenkins/globalVars.yaml.
#
# The file is a flat YAML map. It becomes ConfigMap jenkins-agent-global-vars,
# which the agent pod template in 30-jenkins references via
# `envFrom: configMapRef (optional: true)`, so every agent pod started after
# this is applied has the keys as environment variables. Changing the file and
# re-applying this stack is enough; running builds keep their old values.

locals {
  global_vars_file = "${path.module}/jenkins/globalVars.yaml"
  global_vars_raw  = yamldecode(file(local.global_vars_file))
  # Everything must be a string for a ConfigMap; stringify scalars, reject nested.
  global_vars = { for k, v in local.global_vars_raw : k => tostring(v) }
}

resource "kubernetes_config_map" "agent_global_vars" {
  metadata {
    name      = "jenkins-agent-global-vars"
    namespace = local.jenkins.namespace
    labels    = { "app.kubernetes.io/part-of" = "jenkins", "jenkins.io/global-vars" = "agent" }
    annotations = {
      "jenkins.io/source" = "jenkins/globalVars.yaml"
    }
  }
  data = local.global_vars

  lifecycle {
    precondition {
      condition     = alltrue([for k, v in local.global_vars_raw : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k))])
      error_message = "jenkins/globalVars.yaml: every key must be a valid environment variable name (letters, digits, underscore; not starting with a digit)."
    }
    precondition {
      condition     = alltrue([for k, v in local.global_vars_raw : can(tostring(v))])
      error_message = "jenkins/globalVars.yaml: values must be scalars (quote numbers and booleans); nested maps/lists are not allowed."
    }
  }
}

output "agent_global_vars" {
  description = "Keys injected into every agent pod from jenkins/globalVars.yaml"
  value       = keys(local.global_vars)
}
