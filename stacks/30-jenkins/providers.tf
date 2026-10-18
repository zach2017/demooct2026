data "terraform_remote_state" "cluster" {
  backend = "local"
  config  = { path = "${path.module}/../00-cluster/terraform.tfstate" }
}

locals {
  cluster = data.terraform_remote_state.cluster.outputs
}

provider "kubernetes" {
  host                   = local.cluster.endpoint
  client_certificate     = local.cluster.client_certificate
  client_key             = local.cluster.client_key
  cluster_ca_certificate = local.cluster.cluster_ca_certificate
}

provider "helm" {
  kubernetes {
    host                   = local.cluster.endpoint
    client_certificate     = local.cluster.client_certificate
    client_key             = local.cluster.client_key
    cluster_ca_certificate = local.cluster.cluster_ca_certificate
  }
}

provider "kubectl" {
  load_config_file       = false
  host                   = local.cluster.endpoint
  client_certificate     = local.cluster.client_certificate
  client_key             = local.cluster.client_key
  cluster_ca_certificate = local.cluster.cluster_ca_certificate
}

data "terraform_remote_state" "nodes" {
  backend = "local"
  config  = { path = "${path.module}/../10-nodes/terraform.tfstate" }
}

data "terraform_remote_state" "istio" {
  backend = "local"
  config  = { path = "${path.module}/../20-istio/terraform.tfstate" }
}

locals {
  nodes = data.terraform_remote_state.nodes.outputs
  istio = data.terraform_remote_state.istio.outputs
}
