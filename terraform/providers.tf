# All Kubernetes-facing providers are configured straight from the kind
# cluster resource (cluster.tf). The values are unknown until the cluster
# exists, which is fine for the resources used here: kubernetes_*, helm_release
# and kubectl_manifest only talk to the API server at apply time, not at plan
# time. (kubernetes_manifest would NOT work this way -- that is why Istio
# objects use kubectl_manifest, exactly as in stacks/.)
#
# Consequence: a change that REPLACES the cluster (worker_count, node image,
# cluster_name) must be done as `terraform destroy` + `terraform apply`, not a
# single apply -- see README "Single root module".

provider "kubernetes" {
  host                   = kind_cluster.this.endpoint
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.this.endpoint
    client_certificate     = kind_cluster.this.client_certificate
    client_key             = kind_cluster.this.client_key
    cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  }
}

provider "kubectl" {
  load_config_file       = false
  host                   = kind_cluster.this.endpoint
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
}
