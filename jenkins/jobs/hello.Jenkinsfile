// Seeded into Jenkins by JCasC (see jenkins/values.yaml.tftpl).
// Runs on the default Kubernetes agent pod, which has the jenkins-global-env
// ConfigMap injected via envFrom, so HELLO_IMAGE / HELLO_IMAGE_TAG are plain
// OS env vars in the pod AND Jenkins global env vars on the controller.

pipeline {
  agent any   // default kubernetes pod template from the Helm chart

  environment {
    // Build the image reference once from the global vars.
    HELLO_IMAGE_REF = "${env.HELLO_IMAGE}:${env.HELLO_IMAGE_TAG}"
    SRC_DIR         = "src"
  }

  stages {
    stage('Show global env') {
      steps {
        sh '''
          echo "HELLO_IMAGE      = $HELLO_IMAGE"
          echo "HELLO_IMAGE_TAG  = $HELLO_IMAGE_TAG"
          echo "DOCKER_REGISTRY  = $DOCKER_REGISTRY"
          echo "ENVIRONMENT_NAME = $ENVIRONMENT_NAME"
          echo "HELLO_IMAGE_REF  = $HELLO_IMAGE_REF"
        '''
      }
    }

    stage('Fetch source') {
      steps {
        script {
          if (params.SRC_REPO?.trim()) {
            git url: params.SRC_REPO, branch: params.SRC_BRANCH
          } else {
            // Bundled sample mounted into the agent pod from the hello-src ConfigMap.
            sh 'mkdir -p "$SRC_DIR" && cp /bundled-src/* "$SRC_DIR"/'
          }
        }
      }
    }

    stage('Render Dockerfile') {
      steps {
        sh '''
          set -eu
          DOCKERFILE="$SRC_DIR/Dockerfile"
          echo "--- before ---"; cat "$DOCKERFILE"

          # Replace the placeholders with the values from the global env ConfigMap.
          sed -i \
            -e "s|__HELLO_IMAGE__|$HELLO_IMAGE|g" \
            -e "s|__HELLO_IMAGE_TAG__|$HELLO_IMAGE_TAG|g" \
            "$DOCKERFILE"

          echo "--- after ---"; cat "$DOCKERFILE"

          # Fail loudly if any placeholder survived.
          if grep -q '__HELLO_IMAGE' "$DOCKERFILE"; then
            echo "Unresolved placeholder in $DOCKERFILE" >&2; exit 1
          fi
        '''
      }
    }

    stage('Hello') {
      steps {
        sh 'echo "Hello from $ORG_NAME ($ENVIRONMENT_NAME) - Dockerfile now builds FROM $HELLO_IMAGE_REF"'
        archiveArtifacts artifacts: "${SRC_DIR}/Dockerfile", fingerprint: true
      }
    }
  }
}
