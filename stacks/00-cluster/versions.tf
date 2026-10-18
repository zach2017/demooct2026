terraform {
  required_version = ">= 1.5"
  required_providers {
    kind = { source = "tehcyx/kind", version = "~> 0.5" }
  }
  backend "local" { path = "terraform.tfstate" }
}
