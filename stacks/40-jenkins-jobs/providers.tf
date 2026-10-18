data "terraform_remote_state" "cluster" {
  backend = "local"
  config  = { path = "${path.module}/../../state/00-cluster.tfstate" }
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

data "terraform_remote_state" "jenkins" {
  backend = "local"
  config  = { path = "${path.module}/../../state/30-jenkins.tfstate" }
}

locals {
  jenkins = data.terraform_remote_state.jenkins.outputs
}
