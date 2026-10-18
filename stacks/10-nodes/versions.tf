terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm", version = "~> 2.15" }
    kubectl    = { source = "gavinbunney/kubectl", version = "~> 1.14" }
  }
  backend "local" { path = "../../state/10-nodes.tfstate" }
}
