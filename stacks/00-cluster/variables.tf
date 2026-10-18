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
  description = "Plain workers. 10-nodes assigns roles: worker #1 = Jenkins controller, the rest = agents. Each node costs ~400MB RAM."
  type        = number
  default     = 2
}

variable "ingress_http_host_port" {
  description = "localhost port mapped to NodePort 30080 (Istio ingress HTTP)"
  type        = number
  default     = 8080
}

variable "ingress_https_host_port" {
  description = "localhost port mapped to NodePort 30443 (Istio ingress HTTPS)"
  type        = number
  default     = 8443
}
