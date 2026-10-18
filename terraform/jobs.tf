# ---------------------------------------------------------------------------
# Layer 40 -- Jenkins jobs as JCasC ConfigMaps + agent-only global vars + the
# bundled sample source. (stacks/40-jenkins-jobs/{main,global-vars}.tf)
#
# The Jenkins chart runs a config-reload sidecar that watches ConfigMaps in the
# namespace carrying the label `<release>-jenkins-config: "true"`, copies their
# keys into /var/jenkins_home/casc_configs and triggers a JCasC reload. The
# `jobs:` section is Job DSL, so adding/changing a job here creates/updates it
# in the running controller without a restart or a Helm upgrade.
#
# One ConfigMap per job: add a new file under jenkins/jobs/<name>.Jenkinsfile
# and an entry in local.jobs.
# ---------------------------------------------------------------------------

locals {
  # The chart's config-reload sidecar picks up any ConfigMap carrying this label.
  casc_configmap_label = { "${helm_release.jenkins.name}-jenkins-config" = "true" }

  jobs = {
    hello = {
      description = "Renders src/Dockerfile using the global HELLO_IMAGE / HELLO_IMAGE_TAG vars"
      script      = file("${path.module}/../jenkins/jobs/hello.Jenkinsfile")
      parameters = {
        SRC_REPO   = ["", "Optional git repo containing a src/ directory. Leave blank to use the bundled sample."]
        SRC_BRANCH = ["main", "Branch to check out when SRC_REPO is set"]
      }
    }
  }
}

resource "kubernetes_config_map" "job" {
  for_each = local.jobs

  metadata {
    name      = "jenkins-job-${each.key}"
    namespace = local.namespace
    labels    = local.casc_configmap_label
  }

  data = {
    "job-${each.key}.yaml" = templatefile("${path.module}/job.yaml.tftpl", {
      name        = each.key
      description = each.value.description
      parameters  = each.value.parameters
      # Escape for a Groovy '''...''' string: backslashes, then any ''' inside the Jenkinsfile.
      script = replace(replace(each.value.script, "\\", "\\\\"), "'''", "\\'\\'\\'")
    })
  }

  # Same ordering as `make apply`: jobs land once the controller is Ready, so
  # the config-reload sidecar hot-loads them exactly as with 40-jenkins-jobs.
  depends_on = [null_resource.wait_for_jenkins]
}

# Sample source for the hello job: src/Dockerfile with placeholder tag, mounted
# into agent pods at /bundled-src (the mount is `optional`, so Jenkins starts
# fine before this is created).
resource "kubernetes_config_map" "hello_src" {
  metadata {
    name      = "hello-src"
    namespace = local.namespace
  }
  data = {
    "Dockerfile" = file("${path.module}/../src/Dockerfile")
    "hello.sh"   = file("${path.module}/../src/hello.sh")
  }
}

# ---------------------------------------------------------------------------
# Agent-wide global env from jenkins/globalVars.yaml.
#
# The file is a flat YAML map. It becomes ConfigMap jenkins-agent-global-vars,
# which the agent pod template references via
# `envFrom: configMapRef (optional: true)`, so every agent pod started after
# this is applied has the keys as environment variables.
# ---------------------------------------------------------------------------
locals {
  global_vars_file = "${path.module}/../jenkins/globalVars.yaml"
  global_vars_raw  = yamldecode(file(local.global_vars_file))
  # Everything must be a string for a ConfigMap; stringify scalars, reject nested.
  global_vars = { for k, v in local.global_vars_raw : k => tostring(v) }
}

resource "kubernetes_config_map" "agent_global_vars" {
  metadata {
    name      = "jenkins-agent-global-vars"
    namespace = local.namespace
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
