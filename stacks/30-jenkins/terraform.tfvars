jenkins_image_tag          = "2.580.1-jdk21"   # keep this a current LTS
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
