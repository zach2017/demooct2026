# Tutorial: Jenkins Pods Environment Configuration and Code Walkthrough

**Repository:** https://github.com/zach2017/demooct2026  
**Focus:** How environment variables are configured for Jenkins pods (controller and agents), and a section-by-section, line-by-line explanation of the relevant code.

This repository deploys Jenkins on a local kind Kubernetes cluster with Istio using **five layered Terraform root modules** (stacks). Jobs and certain agent environment variables live in a separate stack so they can be updated without restarting the Jenkins controller.

---

## 1. High-Level Architecture

```
stacks/
  00-cluster/     → kind cluster + kubeconfig
  10-nodes/       → node labels & taints (controller vs agents)
  20-istio/       → Istio control plane + gateways
  30-jenkins/     → Jenkins Helm release, namespace, global env ConfigMap, ingress
  40-jenkins-jobs/→ Jobs as JCasC ConfigMaps + agent-only global vars
```

Data flows via `terraform_remote_state` (local backend files in `state/`).

**Two distinct sources of environment for Jenkins pods:**

| Source | Stack | ConfigMap | Scope | How updated |
|--------|-------|-----------|-------|-------------|
| `var.global_env` | 30-jenkins | `jenkins-global-env` | Agents (`envFrom`) **and** controller (JCasC `globalNodeProperties`) | `make 30-jenkins` (Helm upgrade + JCasC reload) |
| `jenkins/globalVars.yaml` | 40-jenkins-jobs | `jenkins-agent-global-vars` | Agents only (`envFrom`, optional) | `make 40-jenkins-jobs` (no controller restart) |

Agent pods receive **both** via `envFrom`. The agent-specific map is listed last, so its keys override duplicates.

---

## 2. Stack 30-jenkins: Controller + Global Env + Ingress

### 2.1 Namespace and Admin Secret (`stacks/30-jenkins/main.tf`)

```hcl
resource "kubernetes_namespace" "jenkins" {
  metadata {
    name = "jenkins"
    labels = {
      "istio-injection" = var.jenkins_sidecar_injection ? "enabled" : "disabled"
    }
  }
}
```
- Creates the `jenkins` namespace.
- Enables Istio sidecar injection by default (`jenkins_sidecar_injection = true`). Agent pods will get sidecars; the controller can opt out.

```hcl
resource "random_password" "jenkins_admin" { ... }
locals {
  jenkins_admin_password = var.jenkins_admin_password != "" ? var.jenkins_admin_password : random_password.jenkins_admin.result
  ...
}
resource "kubernetes_secret" "jenkins_admin" { ... }
```
- Generates or uses a provided admin password and stores it in a Secret referenced by the Helm chart.

### 2.2 Global Environment ConfigMap

```hcl
resource "kubernetes_config_map" "global_env" {
  metadata {
    name      = "jenkins-global-env"
    namespace = local.namespace
  }
  data = var.global_env
}
```
- `var.global_env` (from `terraform.tfvars` or defaults) becomes the ConfigMap data.
- Example values (from `terraform.tfvars`):
  - `HELLO_IMAGE = "hello-world"`
  - `HELLO_IMAGE_TAG = "linux"`
  - `DOCKER_REGISTRY`, `ORG_NAME`, `ENVIRONMENT_NAME`

This ConfigMap is consumed in two places (explained next).

### 2.3 Helm Release of Jenkins

```hcl
resource "helm_release" "jenkins" {
  ...
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
```
- Renders `jenkins/values.yaml.tftpl` with the values above and passes it to the official Jenkins Helm chart.
- Remote state from `10-nodes` supplies `controller_selector` and `agent_selector`.

### 2.4 Startup Watcher

```hcl
resource "null_resource" "wait_for_jenkins" {
  triggers = { release = helm_release.jenkins.id, rev = helm_release.jenkins.metadata[0].revision }
  provisioner "local-exec" {
    command = "${path.module}/../../scripts/wait-for-jenkins.sh ..."
  }
}
```
- Streams pod status, events, and logs until Jenkins is Ready. Output also goes to `jenkins-startup.log`.

### 2.5 Ingress (Istio Gateway + VirtualService)

Uses remote state from `20-istio` for the ingress gateway selector. Routes traffic from the kind NodePort through the Istio Gateway to the Jenkins Service.

---

## 3. Helm Values Template: Pod Configuration (`jenkins/values.yaml.tftpl`)

This file is the heart of how pods are configured.

### 3.1 Controller Section

```yaml
controller:
  admin:
    existingSecret: jenkins-admin
    ...
  serviceType: ClusterIP
  jenkinsUrl: ${jenkins_url}
  podAnnotations:
    sidecar.istio.io/inject: "${controller_sidecar ? "true" : "false"}"
  nodeSelector:
    # from 10-nodes controller_selector
  tolerations:
    - key: role
      operator: Equal
      value: jenkins-controller
      effect: NoSchedule
  sidecars:
    configAutoReload:
      enabled: true   # watches labeled ConfigMaps → JCasC reload
  ...
  JCasC:
    defaultConfig: true
    configScripts:
      global-env: |
        jenkins:
          globalNodeProperties:
            - envVars:
                env:
%{ for k, v in global_env }
                  - key: "${k}"
                    value: "${v}"
%{ endfor }
```
**Line-by-line notes:**
- Controller is pinned to the node labeled `role=jenkins-controller` and tolerates the matching taint.
- Sidecar injection is **off by default** (`jenkins_controller_sidecar = false`) because the plugin-download init container and startup probes often stall behind an Istio proxy.
- `configAutoReload` enables the sidecar that watches ConfigMaps labeled `jenkins-jenkins-config=true` (used by the jobs stack).
- **JCasC `globalNodeProperties`**: Injects every key from `var.global_env` as a Jenkins-level environment variable. These are available as `env.HELLO_IMAGE` in Groovy (including outside of `node` blocks) on the controller.

### 3.2 Agent Section (Critical for Pod Env)

```yaml
agent:
  nodeSelector:
    # from 10-nodes agent_selector
  yamlMergeStrategy: merge
  yamlTemplate: |-
    apiVersion: v1
    kind: Pod
    spec:
      tolerations:
        - key: role
          operator: Equal
          value: jenkins-agent
          effect: NoSchedule
      containers:
        - name: jnlp
          envFrom:
            - configMapRef:
                name: ${global_env_configmap}          # jenkins-global-env
            - configMapRef:
                name: jenkins-agent-global-vars        # from 40-jenkins-jobs
                optional: true
          volumeMounts:
            - name: hello-src
              mountPath: /bundled-src
      volumes:
        - name: hello-src
          configMap:
            name: hello-src
            optional: true
```
**Line-by-line explanation of agent env:**
1. `yamlMergeStrategy: merge` + `yamlTemplate` merges this Pod spec into the chart’s default agent template.
2. Toleration allows the pod to schedule on nodes tainted with `role=jenkins-agent`.
3. **`envFrom` (the key mechanism):**
   - First ConfigMap: `jenkins-global-env` (created by stack 30). Every key becomes an environment variable in the `jnlp` container (and any other containers if they inherit).
   - Second ConfigMap: `jenkins-agent-global-vars` (created by stack 40). Listed **after** the first so its values win on key collisions. `optional: true` means the pod can still start if the ConfigMap does not yet exist.
4. Volume mount for the sample `hello-src` ConfigMap (created by stack 40) so the `hello` job can access a bundled Dockerfile without cloning a repo.

---

## 4. Stack 40-jenkins-jobs: Jobs + Agent-Only Global Vars

### 4.1 Agent Global Vars (`global-vars.tf`)

```hcl
locals {
  global_vars_file = "${path.module}/jenkins/globalVars.yaml"
  global_vars_raw  = yamldecode(file(local.global_vars_file))
  global_vars = { for k, v in local.global_vars_raw : k => tostring(v) }
}

resource "kubernetes_config_map" "agent_global_vars" {
  metadata {
    name      = "jenkins-agent-global-vars"
    namespace = local.jenkins.namespace
    ...
  }
  data = local.global_vars

  lifecycle {
    precondition { ... keys must be valid env var names ... }
    precondition { ... values must be scalars ... }
  }
}
```
- Reads `jenkins/globalVars.yaml` (flat map of strings).
- Creates ConfigMap `jenkins-agent-global-vars`.
- Preconditions enforce that keys are valid environment variable names and values are scalars.
- Changing this file and re-applying only stack 40 updates the ConfigMap; **new agent pods** pick up the values. Running builds keep the old environment.

Example content of `globalVars.yaml`:
```yaml
GLOBAL_GREETING: "Hello from globalVars.yaml"
BUILD_TEAM: "platform"
DEFAULT_BRANCH: "main"
ARTIFACT_RETENTION_DAYS: "14"
```

### 4.2 Jobs as ConfigMaps (`main.tf`)

```hcl
locals {
  jobs = {
    hello = {
      description = "..."
      script      = file("${path.module}/../../jenkins/jobs/hello.Jenkinsfile")
      parameters = { ... }
    }
  }
}

resource "kubernetes_config_map" "job" {
  for_each = local.jobs
  metadata {
    name      = "jenkins-job-${each.key}"
    namespace = local.jenkins.namespace
    labels    = local.jenkins.casc_configmap_label   # triggers reload
  }
  data = {
    "job-${each.key}.yaml" = templatefile("${path.module}/job.yaml.tftpl", { ... })
  }
}
```
- Each job becomes a ConfigMap labeled so the config-reload sidecar detects it, copies the YAML into the casc configs directory, and triggers a JCasC reload.
- The Job DSL script is generated from `job.yaml.tftpl` and the Jenkinsfile content.
- No Helm upgrade or controller restart is required.

Also creates `hello-src` ConfigMap with the sample Dockerfile and script that agents mount.

---

## 5. How a Pipeline Sees the Environment (`hello.Jenkinsfile`)

```groovy
pipeline {
  agent any

  environment {
    HELLO_IMAGE_REF = "${env.HELLO_IMAGE}:${env.HELLO_IMAGE_TAG}"
    ...
  }

  stages {
    stage('Show global env') {
      steps {
        sh '''
          echo "HELLO_IMAGE      = $HELLO_IMAGE"
          echo "GLOBAL_GREETING  = ${GLOBAL_GREETING:-<not set>}"
          ...
        '''
      }
    }
    ...
  }
}
```
- `agent any` uses the default Kubernetes pod template (which has the `envFrom` above).
- `$HELLO_IMAGE` in `sh` comes from the ConfigMap injection.
- `env.HELLO_IMAGE` in Groovy comes from the controller’s JCasC `globalNodeProperties`.
- `GLOBAL_GREETING` comes only from the agent ConfigMap (not set on the controller).

---

## 6. Node Placement (Stack 10-nodes)

```hcl
locals {
  controller_node = local.workers[0]
  agent_nodes     = slice(local.workers, 1, length(local.workers))
  roles = merge(
    { (local.controller_node) = "jenkins-controller" },
    { for n in local.agent_nodes : n => "jenkins-agent" },
  )
}
# Labels + taints applied to the nodes
```
- First worker → controller (taint `role=jenkins-controller:NoSchedule`).
- Remaining workers → agents (taint `role=jenkins-agent:NoSchedule`).
- Selectors and tolerations in the Helm values pin the pods accordingly.

---

## 7. Operational Summary

| Action | Command | Effect on pods / env |
|--------|---------|----------------------|
| Change controller global env | Edit `global_env` in 30, `make 30-jenkins` | Helm upgrade + JCasC reload; new agents + controller see it |
| Change agent-only vars | Edit `jenkins/globalVars.yaml`, `make 40-jenkins-jobs` | ConfigMap update; next agent pods see it (no restart) |
| Add/change a job | Add Jenkinsfile + entry in `local.jobs`, `make 40-jenkins-jobs` | ConfigMap + JCasC reload (~30 s) |
| Move controller pod | Change node labels, delete pod | Controller reschedules |

Destroy guards and dependency checks (`check-deps.sh`) prevent accidental destruction of upstream stacks while downstream objects still exist.

---

## 8. Key Design Decisions

1. **Separation of jobs and agent env into stack 40** — allows hot updates without controller restarts.
2. **Dual injection of `global_env`** — ConfigMap for pods + JCasC for Groovy on the controller.
3. **Optional ConfigMap reference** — agents can start before stack 40 is applied.
4. **Controller sidecar off by default** — avoids common first-boot stalls.
5. **Local remote state + explicit ordering** — each stack is independently applyable/destroyable while still sharing data.

This pattern gives strong modularity while keeping the Jenkins experience simple for pipeline authors. 
