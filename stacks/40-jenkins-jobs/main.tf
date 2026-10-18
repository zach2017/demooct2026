# Stack 40: Jenkins jobs, delivered as JCasC ConfigMaps.
#
# The Jenkins chart runs a config-reload sidecar that watches ConfigMaps in the
# namespace carrying the label `<release>-jenkins-config: "true"`, copies their
# keys into /var/jenkins_home/casc_configs and triggers a JCasC reload. The
# `jobs:` section is Job DSL, so adding/changing a job here creates/updates it
# in the running controller without a restart or a Helm upgrade.
#
# One ConfigMap per job: add a new file under jenkins/jobs/<name>.Jenkinsfile
# and an entry in local.jobs.

locals {
  jobs = {
    hello = {
      description = "Renders src/Dockerfile using the global HELLO_IMAGE / HELLO_IMAGE_TAG vars"
      script      = file("${path.module}/../../jenkins/jobs/hello.Jenkinsfile")
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
    namespace = local.jenkins.namespace
    labels    = local.jenkins.casc_configmap_label
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
}

# Sample source for the hello job: src/Dockerfile with placeholder tag, mounted
# into agent pods at /bundled-src (the mount is `optional`, so Jenkins starts
# fine before this stack is applied).
resource "kubernetes_config_map" "hello_src" {
  metadata {
    name      = "hello-src"
    namespace = local.jenkins.namespace
  }
  data = {
    "Dockerfile" = file("${path.module}/../../src/Dockerfile")
    "hello.sh"   = file("${path.module}/../../src/hello.sh")
  }
}
