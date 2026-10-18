terraform {
  required_version = ">= 1.5"
  required_providers {
    kind       = { source = "tehcyx/kind", version = "~> 0.5" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm", version = "~> 2.15" }
    kubectl    = { source = "gavinbunney/kubectl", version = "~> 1.14" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
    null       = { source = "hashicorp/null", version = "~> 3.2" }
  }
  # One state file for the whole platform, next to the per-stack ones
  # (state/ is git-ignored).
  backend "local" { path = "../state/single.tfstate" }
}
