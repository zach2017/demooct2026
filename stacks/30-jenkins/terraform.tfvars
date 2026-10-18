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
