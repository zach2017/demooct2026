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
