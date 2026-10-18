output "namespace" { value = kubernetes_namespace.istio_system.metadata[0].name }
output "ingress_gateway_selector" { value = { istio = "ingressgateway" } }
output "egress_hosts" { value = var.egress_hosts }
output "istiod_release" { value = helm_release.istiod.name }
