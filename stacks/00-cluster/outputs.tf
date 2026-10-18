output "cluster_name" { value = kind_cluster.this.name }
output "kubeconfig_path" { value = kind_cluster.this.kubeconfig_path }
output "endpoint" { value = kind_cluster.this.endpoint }
output "client_certificate" {
  value     = kind_cluster.this.client_certificate
  sensitive = true
}
output "client_key" {
  value     = kind_cluster.this.client_key
  sensitive = true
}
output "cluster_ca_certificate" {
  value     = kind_cluster.this.cluster_ca_certificate
  sensitive = true
}
output "ingress_http_host_port" { value = var.ingress_http_host_port }

# kind names workers <cluster>-worker, <cluster>-worker2, <cluster>-worker3 ...
output "worker_node_names" {
  value = [for i in range(var.worker_count) : i == 0 ? "${var.cluster_name}-worker" : "${var.cluster_name}-worker${i + 1}"]
}
