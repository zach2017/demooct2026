# Same values as stacks/*/terraform.tfvars, merged into one file.

# --- cluster (00) ---
cluster_name            = "jenkins2"
worker_count            = 2       # 1 controller node + 1 agent node
ingress_http_host_port  = 8085
ingress_https_host_port = 8445

# --- istio (20) ---
istio_version = "1.24.2"
egress_hosts  = ["github.com"]

# --- jenkins (30) ---
jenkins_chart_version      = "5.9.69"   # chart appVersion = Jenkins image; keep current
# jenkins_image_tag        = ""         # leave empty to use the chart's appVersion
jenkins_controller_sidecar = false
jenkins_sidecar_injection  = true

# -> jenkins-global-env ConfigMap -> every agent pod + Jenkins global env
global_env = {
  HELLO_IMAGE      = "hello-world"
  HELLO_IMAGE_TAG  = "linux"
  DOCKER_REGISTRY  = "docker.io"
  ORG_NAME         = "acme"
  ENVIRONMENT_NAME = "local"
}
