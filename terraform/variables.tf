# Every variable from stacks/*/variables.tf, same names and defaults, so a
# terraform.tfvars written for a stack can be pasted here unchanged.

# --- 00-cluster ---------------------------------------------------------------

variable "cluster_name" {
  type    = string
  default = "jenkins"
}

variable "kind_node_image" {
  description = "kindest/node image; pin to the tag `kind version` recommends"
  type        = string
  default     = "kindest/node:v1.31.2"
}

variable "kubeconfig_path" {
  type    = string
  default = "~/.kube/kind-jenkins.yaml"
}

variable "worker_count" {
  description = "Plain workers. Worker #1 = Jenkins controller, the rest = agents (see nodes.tf). Each node costs ~400MB RAM. Changing this REPLACES the cluster."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 2
    error_message = "worker_count must be >= 2: one controller node plus at least one agent node."
  }
}

variable "ingress_http_host_port" {
  description = "localhost port mapped to NodePort 30080 (Istio ingress HTTP)"
  type        = number
  default     = 8085
}

variable "ingress_https_host_port" {
  description = "localhost port mapped to NodePort 30443 (Istio ingress HTTPS)"
  type        = number
  default     = 8445
}

# --- 20-istio -----------------------------------------------------------------

variable "istio_version" {
  description = "Istio Helm chart version (base, istiod, gateway all share it)"
  type        = string
  default     = "1.24.2"
}

variable "egress_hosts" {
  description = <<-EOT
    External HTTPS hosts that mesh workloads reach via the Istio egress gateway
    (TLS passthrough). Keep Jenkins' plugin mirrors (updates.jenkins.io,
    get.jenkins.io) OUT of this list.
  EOT
  type        = list(string)
  default     = ["github.com"]
}

# --- 30-jenkins ---------------------------------------------------------------

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
