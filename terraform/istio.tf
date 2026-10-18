# ---------------------------------------------------------------------------
# Layer 20 -- Istio: CRDs + istiod + ingress gateway + egress gateway (official
# Helm charts), plus the egress ServiceEntry/Gateway/VirtualService.
# (stacks/20-istio/main.tf)
# ---------------------------------------------------------------------------
locals {
  istio_repo = "https://istio-release.storage.googleapis.com/charts"
  # Istio control plane + gateways run on the kind control-plane node.
  infra_node = { "node-role.kubernetes.io/control-plane" = "" }
  cp_toleration = [{
    key      = "node-role.kubernetes.io/control-plane"
    operator = "Exists"
    effect   = "NoSchedule"
  }]
  ingress_gateway_selector = { istio = "ingressgateway" }
}

resource "kubernetes_namespace" "istio_system" {
  metadata {
    name = "istio-system"
  }
  depends_on = [kind_cluster.this]
}

resource "helm_release" "istio_base" {
  name       = "istio-base"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = local.istio_repo
  chart      = "base"
  version    = var.istio_version

  set {
    name  = "defaultRevision"
    value = "default"
  }
}

resource "helm_release" "istiod" {
  name       = "istiod"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = local.istio_repo
  chart      = "istiod"
  version    = var.istio_version
  timeout    = 600
  wait       = true

  values = [yamlencode({
    pilot = {
      nodeSelector = local.infra_node
      tolerations  = local.cp_toleration
      resources    = { requests = { cpu = "100m", memory = "512Mi" } }
      env = {
        # Inject the proxy as a native (restartPolicy: Always) init container.
        # Required so Jenkins agent pods terminate cleanly when the jnlp
        # container exits instead of hanging on a live istio-proxy.
        ENABLE_NATIVE_SIDECARS = "true"
      }
    }
    meshConfig = {
      accessLogFile = "/dev/stdout"
      # Keep ALLOW_ANY so traffic to hosts not listed in egress_hosts still
      # works; the hosts that ARE listed are forced through the egress gateway.
      outboundTrafficPolicy = { mode = "ALLOW_ANY" }
    }
  })]

  depends_on = [helm_release.istio_base]
}

# Ingress gateway: NodePort pinned to 30080/30443, which cluster.tf maps to localhost.
resource "helm_release" "istio_ingress" {
  name       = "istio-ingressgateway"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = local.istio_repo
  chart      = "gateway"
  version    = var.istio_version
  timeout    = 600

  values = [yamlencode({
    nodeSelector = local.infra_node
    tolerations  = local.cp_toleration
    resources    = { requests = { cpu = "50m", memory = "64Mi" } }
    service = {
      type = "NodePort"
      ports = [
        { name = "status-port", port = 15021, targetPort = 15021, nodePort = 30021 },
        { name = "http2", port = 80, targetPort = 80, nodePort = 30080 },
        { name = "https", port = 443, targetPort = 443, nodePort = 30443 },
      ]
    }
  })]

  depends_on = [helm_release.istiod]
}

# Egress gateway: cluster-internal; mesh workloads are steered to it by the
# VirtualService below for the hosts in var.egress_hosts.
resource "helm_release" "istio_egress" {
  name       = "istio-egressgateway"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = local.istio_repo
  chart      = "gateway"
  version    = var.istio_version
  timeout    = 600

  values = [yamlencode({
    nodeSelector = local.infra_node
    tolerations  = local.cp_toleration
    resources    = { requests = { cpu = "50m", memory = "64Mi" } }
    service      = { type = "ClusterIP" }
  })]

  depends_on = [helm_release.istiod]
}

# ---------------------------------------------------------------------------
# Egress: ServiceEntry + Gateway + VirtualService
# Mesh sidecar -> istio-egressgateway -> external host (TLS passthrough on 443)
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "egress_serviceentry" {
  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "ServiceEntry"
    metadata   = { name = "egress-https-hosts", namespace = "istio-system" }
    spec = {
      hosts      = var.egress_hosts
      location   = "MESH_EXTERNAL"
      resolution = "DNS"
      ports      = [{ number = 443, name = "tls", protocol = "TLS" }]
    }
  })
  depends_on = [helm_release.istiod]
}

resource "kubectl_manifest" "egress_gateway" {
  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "Gateway"
    metadata   = { name = "egress-gateway", namespace = "istio-system" }
    spec = {
      selector = { istio = "egressgateway" }
      servers = [{
        port  = { number = 443, name = "tls", protocol = "TLS" }
        hosts = var.egress_hosts
        tls   = { mode = "PASSTHROUGH" }
      }]
    }
  })
  depends_on = [helm_release.istio_egress]
}

# One VirtualService with two hops per host:
#   1. from any sidecar ("mesh")   -> egress gateway service
#   2. from the egress gateway     -> the real external host
resource "kubectl_manifest" "egress_virtualservice" {
  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "VirtualService"
    metadata   = { name = "egress-via-gateway", namespace = "istio-system" }
    spec = {
      hosts    = var.egress_hosts
      gateways = ["mesh", "egress-gateway"]
      tls = concat(
        [for h in var.egress_hosts : {
          match = [{ gateways = ["mesh"], port = 443, sniHosts = [h] }]
          route = [{
            destination = {
              host = "istio-egressgateway.istio-system.svc.cluster.local"
              port = { number = 443 }
            }
          }]
        }],
        [for h in var.egress_hosts : {
          match = [{ gateways = ["egress-gateway"], port = 443, sniHosts = [h] }]
          route = [{ destination = { host = h, port = { number = 443 } } }]
        }]
      )
    }
  })
  depends_on = [kubectl_manifest.egress_gateway, kubectl_manifest.egress_serviceentry]
}
