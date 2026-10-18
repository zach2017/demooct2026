variable "jenkins_host" {
  description = "Host the Istio Gateway/VirtualService match for Jenkins ('*' = any)"
  type        = string
  default     = "*"
}

variable "jenkins_sidecar_injection" {
  description = "Inject Istio sidecars into the jenkins namespace. Set false to take Jenkins out of the mesh when debugging; ingress via the Gateway still works."
  type        = bool
  default     = true
}

variable "jenkins_controller_sidecar" {
  description = <<-EOT
    Inject an Istio sidecar into the Jenkins CONTROLLER pod. Default false: the
    controller's plugin-download init container and startup probes are the
    most common thing to stall behind a sidecar on first boot, and the
    controller doesn't need egress routing. Agent pods are unaffected and stay
    in the mesh (jenkins_sidecar_injection). Ingress still goes through the
    Istio Gateway; mTLS is PERMISSIVE so the gateway reaches it over plain HTTP.
  EOT
  type        = bool
  default     = false
}

variable "jenkins_helm_timeout" {
  description = "Seconds to wait for the Jenkins release to become ready"
  type        = number
  default     = 1800
}

# --- Jenkins ----------------------------------------------------------------

variable "jenkins_chart_version" {
  description = "jenkinsci/jenkins Helm chart version. Its appVersion is the Jenkins image used unless jenkins_image_tag overrides it. Keep this current: an old chart's default JCasC can reference attributes removed from newer cores (e.g. excludeClientIPFromCrumb)."
  type        = string
  default     = "5.9.69"
}

variable "jenkins_image_tag" {
  description = <<-EOT
    Optional jenkins/jenkins image tag override. Empty (default) uses the
    chart's appVersion, which the chart's default JCasC and plugin bundle are
    tested against. If you do override it, pick a current LTS
    (https://www.jenkins.io/changelog-stable/): the chart installs the latest
    plugin releases, which require a recent core.
  EOT
  type        = string
  default     = ""
}

variable "jenkins_admin_user" {
  type    = string
  default = "admin"
}

variable "jenkins_admin_password" {
  description = "Admin password. Leave empty to generate one (see output)."
  type        = string
  default     = ""
  sensitive   = true
}

# --- Global pipeline environment --------------------------------------------

variable "global_env" {
  description = <<-EOT
    Key/value pairs placed in the jenkins-global-env ConfigMap. Every agent pod
    receives them as environment variables, and JCasC also exposes them as
    Jenkins global env vars on the controller.
  EOT
  type        = map(string)
  default = {
    HELLO_IMAGE      = "hello-world"
    HELLO_IMAGE_TAG  = "latest"
    DOCKER_REGISTRY  = "docker.io"
    ORG_NAME         = "example"
    ENVIRONMENT_NAME = "local"
  }
}
