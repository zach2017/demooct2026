# Stack 30: Jenkins controller + global env + ingress through Istio.
# Jobs are NOT here; see stacks/40-jenkins-jobs.
resource "kubernetes_namespace" "jenkins" {
  metadata {
    name = "jenkins"
    labels = {
      "istio-injection" = var.jenkins_sidecar_injection ? "enabled" : "disabled"
    }
  }
}

resource "random_password" "jenkins_admin" {
  length  = 20
  special = false
}

locals {
  namespace              = kubernetes_namespace.jenkins.metadata[0].name
  jenkins_admin_password = var.jenkins_admin_password != "" ? var.jenkins_admin_password : random_password.jenkins_admin.result
  jenkins_url            = "http://localhost:${local.cluster.ingress_http_host_port}"
}

# ---------------------------------------------------------------------------
# Global environment: one ConfigMap, consumed two ways
#   1. agent pods: envFrom configMapRef (values.yaml.tftpl agent.yamlTemplate)
#   2. controller: JCasC globalNodeProperties (same map rendered into YAML)
# ---------------------------------------------------------------------------
resource "kubernetes_config_map" "global_env" {
  metadata {
    name      = "jenkins-global-env"
    namespace = local.namespace
  }
  data = var.global_env
}

resource "kubernetes_secret" "jenkins_admin" {
  metadata {
    name      = "jenkins-admin"
    namespace = local.namespace
  }
  data = {
    "jenkins-admin-user"     = var.jenkins_admin_user
    "jenkins-admin-password" = local.jenkins_admin_password
  }
}

resource "helm_release" "jenkins" {
  name       = "jenkins"
  namespace  = local.namespace
  repository = "https://charts.jenkins.io"
  chart      = "jenkins"
  version    = var.jenkins_chart_version

  wait          = false
  wait_for_jobs = false
  timeout       = 600

  values = [
    templatefile("${path.module}/../../jenkins/values.yaml.tftpl", {
      global_env_configmap = kubernetes_config_map.global_env.metadata[0].name
      global_env           = var.global_env
      jenkins_url          = local.jenkins_url
      controller_sidecar   = var.jenkins_controller_sidecar
      jenkins_image_tag    = var.jenkins_image_tag
      controller_selector  = local.nodes.controller_selector
      agent_selector       = local.nodes.agent_selector
    })
  ]

  depends_on = [kubernetes_config_map.global_env, kubernetes_secret.jenkins_admin]
}

# Streams pod status + logs to the terminal (and jenkins-startup.log) until Ready.
resource "null_resource" "wait_for_jenkins" {
  triggers = { release = helm_release.jenkins.id, rev = helm_release.jenkins.metadata[0].revision }
  provisioner "local-exec" {
    command = "${path.module}/../../scripts/wait-for-jenkins.sh '${local.cluster.kubeconfig_path}' ${local.namespace} ${var.jenkins_helm_timeout} '${path.module}/jenkins-startup.log'"
  }
  depends_on = [helm_release.jenkins]
}

# ---------------------------------------------------------------------------
# Ingress: Gateway + VirtualService -> Jenkins (via 20-istio's ingress gateway)
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "gateway" {
  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "Gateway"
    metadata   = { name = "jenkins-gateway", namespace = local.namespace }
    spec = {
      selector = local.istio.ingress_gateway_selector
      servers = [{
        port  = { number = 80, name = "http", protocol = "HTTP" }
        hosts = [var.jenkins_host]
      }]
    }
  })
}

resource "kubectl_manifest" "virtualservice" {
  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "VirtualService"
    metadata   = { name = "jenkins", namespace = local.namespace }
    spec = {
      hosts    = [var.jenkins_host]
      gateways = ["jenkins-gateway"]
      http = [{
        match   = [{ uri = { prefix = "/" } }]
        route   = [{ destination = { host = "jenkins.${local.namespace}.svc.cluster.local", port = { number = 8080 } } }]
        timeout = "300s"
      }]
    }
  })
  depends_on = [kubectl_manifest.gateway]
}
