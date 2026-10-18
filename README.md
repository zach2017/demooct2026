# Jenkins on kind + Istio — layered Terraform stacks

Five independent Terraform root modules, each with its own `terraform.tfstate`,
applied in order. Downstream stacks read what they need from upstream state via
`terraform_remote_state` (local backend), so you can re-apply or destroy one
layer without touching the others.

```
stacks/
  00-cluster/        kind cluster: control-plane + N plain workers, host-port maps for Istio ingress
  10-nodes/          node roles: labels + taints (worker1 = jenkins-controller, rest = jenkins-agent)
  20-istio/          istio-base, istiod, ingress + egress gateways, egress ServiceEntry/Gateway/VirtualService
  30-jenkins/        namespace (sidecar-injected), jenkins-global-env ConfigMap, Jenkins Helm release,
                     ingress Gateway + VirtualService, startup watcher
  40-jenkins-jobs/   jobs as JCasC ConfigMaps (Job DSL), hot-reloaded into the running controller
jenkins/values.yaml.tftpl        Helm values + JCasC (global env, agent pod template) used by 30-jenkins
jenkins/jobs/*.Jenkinsfile       pipeline scripts used by 40-jenkins-jobs
jenkins/globalVars.yaml          env vars for every agent pod -> ConfigMap jenkins-agent-global-vars (40-jenkins-jobs)
src/                             sample Dockerfile with __HELLO_IMAGE__:__HELLO_IMAGE_TAG__ placeholders
scripts/wait-for-jenkins.sh      prints pod/container/event/log status while Jenkins starts
scripts/diagnose.sh              one-shot dump of everything
scripts/guard-destroy.sh         destroy guard run by each stack's terraform_data.destroy_guard
scripts/lib/check.sh             helpers for the per-stack check-deps.sh scripts
stacks/*/check-deps.sh           pre-apply dependency check for that stack (run by make apply)
OPERATIONS.md                    how to update each stack, what to re-apply, destroy guards
Makefile                         apply/destroy all stacks in order; make single* for terraform/
terraform/                       the SAME platform as ONE root module / one state (see below)
state/                           one state file per stack: 00-cluster.tfstate, 10-nodes.tfstate, ... (git-ignored)
```

Data flow between stacks:

```
00-cluster ──endpoint, certs, kubeconfig_path, worker_node_names──▶ every later stack
10-nodes   ──controller_selector, agent_selector────────────────▶ 30-jenkins
20-istio   ──ingress_gateway_selector───────────────────────────▶ 30-jenkins
30-jenkins ──namespace, casc_configmap_label────────────────────▶ 40-jenkins-jobs
```

## Prerequisites

- Docker with **≥ 6 GB RAM** for the VM (Docker Desktop → Settings → Resources)
- `kind`, `terraform` ≥ 1.5, `kubectl`, `make`

## Deploy

```bash
# optional: copy and edit the *.tfvars.example files in each stack
make init
make apply            # ~10 min first time

eval $(make output)   # sets KUBECONFIG, URL, PASSWORD in your shell
export KUBECONFIG
open $URL             # admin / $PASSWORD  (through the Istio ingress gateway)
```

Or one stack at a time: `make 30-jenkins`, or `terraform -chdir=stacks/30-jenkins apply`.

## Single root module (`terraform/`)

The same platform as one Terraform root module with one state file
(`state/single.tfstate`). Every resource, Helm value, label and ConfigMap is
identical to the stacks; the only difference is that ordering comes from
Terraform's dependency graph instead of `terraform_remote_state` + the Makefile
loop. Use it when you want a one-shot `apply`/`destroy` and don't need to
re-apply layers independently. **Pick one layout per machine** -- both create
kind cluster `jenkins` at the same kubeconfig path, and `terraform/check-deps.sh`
refuses to run while any `state/<stack>.tfstate` still holds resources.

```
terraform/
  cluster.tf      = 00-cluster        nodes.tf   = 10-nodes
  istio.tf        = 20-istio          jenkins.tf = 30-jenkins
  jobs.tf         = 40-jenkins-jobs   (jobs + globalVars.yaml + hello-src)
  providers.tf    kubernetes/helm/kubectl configured from kind_cluster.this
  variables.tf    union of stacks/*/variables.tf, same names and defaults
  terraform.tfvars  the five stack tfvars merged
  guard.tf        destroy guard (refuses while builds are running)
  check-deps.sh   host tooling, files, no overlapping staged deployment
```

```bash
make single           # check-deps + init + apply   (~10 min first time)
eval $(make single-output); export KUBECONFIG; open $URL
make single-plan / single-deps / single-check
make single-destroy   # guarded; FORCE_DESTROY=1 to bypass
```

Or plain Terraform: `terraform -chdir=terraform init && terraform -chdir=terraform apply`.
It reads the same shared files the stacks do (`jenkins/values.yaml.tftpl`,
`jenkins/jobs/*.Jenkinsfile`, `jenkins/globalVars.yaml`, `src/`, `scripts/`),
so editing a Jenkinsfile or `globalVars.yaml` and re-applying works the same
way; it just plans the whole platform (fast: the plan is a no-op for the
unchanged layers).

Two things the staged layout handles better, by design:

- **Replacing the cluster** (`worker_count`, `kind_node_image`, `cluster_name`):
  the Kubernetes providers are configured from `kind_cluster.this`, so a
  single apply that recreates the cluster would try to talk to the old
  endpoint for every in-cluster resource. Do `make single-destroy && make single`
  instead of a single apply.
- **Destroying one layer**: there is no `make destroy-30-jenkins` equivalent;
  `terraform destroy -target=helm_release.jenkins` works but leaves the
  dependency-ordering to you.

## Dependency checks

Every stack directory has a `check-deps.sh`. It verifies what that stack
needs from the host and from the stacks above it — CLIs, upstream state files,
cluster reachability, node roles, CRDs, Istio deployments, the Jenkins pod,
plugins, ConfigMaps, the ingress URL — and prints one line per item:

```
[ OK ]      state: 20-istio                  /…/state/20-istio.tfstate
[ OK ]      node jenkins-worker (role=jenkins-controller)  Ready
[MISSING]   crd: gateways.networking.istio.io   make 20-istio (istio-base CRDs)
[UNHEALTHY] deployment/istiod (ns istio-system)  0/1 ready
            ---- kubectl describe deployment -n istio-system istiod ----
            …
```

`MISSING` tells you which stack (or install step) provides it; `UNHEALTHY`
means the object exists but isn't ready, and the script runs `kubectl describe`
on it so the reason is right there. `make apply` and `make <stack>` run the
check first and stop on failure; `make deps` runs all five without applying,
`make deps-30-jenkins` runs one.

## State layout

Every stack is a local-backend root module whose state lives at
`state/<stack>.tfstate` (set in each `versions.tf`). Downstream stacks read
upstream outputs with `terraform_remote_state` pointing at those same files.

```
state/00-cluster.tfstate      ← read by 10, 20, 30, 40
state/10-nodes.tfstate        ← read by 30
state/20-istio.tfstate        ← read by 30
state/30-jenkins.tfstate      ← read by 40
state/40-jenkins-jobs.tfstate
```

If you applied an earlier version of this repo that kept
`stacks/<stack>/terraform.tfstate`, run `make migrate-state` once; it uses
`terraform init -migrate-state` per stack and removes the old files.

## Why jobs are a separate stack

The Jenkins chart runs a **config-reload sidecar** that watches ConfigMaps in the
namespace labelled `jenkins-jenkins-config: "true"`, copies them into
`/var/jenkins_home/casc_configs` and triggers a JCasC reload. The `jobs:` section
of JCasC is Job DSL, so `40-jenkins-jobs` can add or change pipeline jobs by
writing ConfigMaps — no Helm upgrade, no controller restart.

To add a job: drop `jenkins/jobs/<name>.Jenkinsfile` in, add an entry to
`local.jobs` in `stacks/40-jenkins-jobs/main.tf`, `make 40-jenkins-jobs`. It
appears in Jenkins within ~30 s.

## Global env vars

`global_env` in `30-jenkins` becomes the `jenkins-global-env` ConfigMap, which is:

1. injected into every agent pod via `envFrom` (so `$HELLO_IMAGE` works in `sh`), and
2. declared as Jenkins global env vars via JCasC `globalNodeProperties` (so `env.HELLO_IMAGE` works in Groovy).

There is a second, file-driven map for **agent pods only**: `jenkins/globalVars.yaml`.
`stacks/40-jenkins-jobs/global-vars.tf` turns it into ConfigMap
`jenkins-agent-global-vars`, and the agent pod template injects it with
`envFrom` (optional, listed after `jenkins-global-env`, so its keys win on
collision). Edit the file, `make 40-jenkins-jobs`, and the next build sees the
new values — no controller restart. Keys must be valid env var names and values
scalars (quote numbers/booleans); Terraform preconditions reject anything else.

| | `var.global_env` (30) | `jenkins/globalVars.yaml` (40) |
|---|---|---|
| Source | Terraform variable | YAML file |
| Agent pods (`$VAR` in `sh`) | yes | yes |
| Controller / `env.VAR` in Groovy outside a node | yes (JCasC) | no |
| Change needs | `make 30-jenkins` (Helm upgrade, JCasC reload) | `make 40-jenkins-jobs` |

The `hello` job reads `HELLO_IMAGE`/`HELLO_IMAGE_TAG`, replaces the placeholders in
`src/Dockerfile`, fails if any survive, archives the result, and prints
`GLOBAL_GREETING` / `BUILD_TEAM` from `globalVars.yaml`.

## Networking through Istio

```
browser → localhost:8080 → kind NodePort 30080 → istio-ingressgateway
       → Gateway jenkins-gateway → VirtualService jenkins → jenkins.jenkins.svc:8080

agent pod (sidecar) → TLS github.com:443 → VirtualService egress-via-gateway
       → istio-egressgateway → Gateway egress-gateway (PASSTHROUGH) → github.com
```

- `jenkins` namespace has `istio-injection=enabled`; agent pods get native
  sidecars (`ENABLE_NATIVE_SIDECARS=true`) so they exit cleanly after a build.
- The controller pod opts out via `jenkins_controller_sidecar=false` (default):
  its plugin-download init container and startup probes are the usual things to
  stall behind a proxy, and it needs no egress routing. Flip to `true` once
  everything else works.
- `egress_hosts` (20-istio) are forced through the egress gateway; everything
  else is `ALLOW_ANY`.

## Troubleshooting

`30-jenkins` streams startup progress (pod phase, each container's state and
restarts, events, `init`/`jenkins` log tails) to the terminal and
`stacks/30-jenkins/jenkins-startup.log`. What the output means:

| You see | Cause | Fix |
|---|---|---|
| `connection refused` on `127.0.0.1:<port>` from `kubectl`/`helm` | wrong kubeconfig, or kind control-plane crashed (OOM) | `export KUBECONFIG=~/.kube/kind-jenkins.yaml`; `docker ps -a --filter name=jenkins-` |
| `init  waiting ... BackOff`, `[init prev] <plugin> requires a greater version of Jenkins` | Jenkins image older than current plugins need | bump `jenkins_chart_version` (its appVersion is the image); only set `jenkins_image_tag` if you must override |
| `jenkins CrashLoopBackOff`, `[jenkins prev] UnknownAttributesException … DefaultCrumbIssuer : excludeClientIPFromCrumb` | chart older than the Jenkins core: its default JCasC uses a removed attribute | bump `jenkins_chart_version`; keep chart and image in step |
| `init  waiting ImagePullBackOff` | can't pull from Docker Hub | check Docker network/proxy |
| `init  running` for minutes, log stuck on a URL | plugin download blocked | keep `jenkins_controller_sidecar=false`; check host egress |
| `jenkins running restarts=N`, `Startup probe failed` | slow first boot | raise `probes.startupProbe.failureThreshold` in values |
| `jenkins waiting restarts=N CrashLoopBackOff`, `[jenkins prev] ConfiguratorException` / `while scanning` | JCasC YAML rejected; Jenkins exits on a bad config | the watcher prints the first error; check the rendered values: `helm -n jenkins get values jenkins` |
| job missing after `make 40-jenkins-jobs` | reload sidecar didn't pick it up | `kubectl -n jenkins logs jenkins-0 -c config-reload`; check the ConfigMap label |

Failed Helm release stuck in state: `helm -n jenkins uninstall jenkins` then
re-apply `30-jenkins`. Full snapshot: `scripts/diagnose.sh > diagnose.txt`.

## Tear down

```bash
make check            # run every stack's destroy guard without destroying anything
make destroy          # 40 → 30 → 20 → 10 → 00, each guarded
make destroy-30-jenkins   # one stack; refuses if 40-jenkins-jobs still exists
```

Each stack carries a `terraform_data.destroy_guard` with a destroy-time
provisioner, so a bare `terraform destroy` is guarded too: it prints what is
blocking (downstream state, dependent namespaces, Gateways, sidecar-injected
namespaces, running builds) with the `kubectl`/`terraform` command that shows
the object, and aborts before touching anything. `FORCE_DESTROY=1` bypasses it.
See **OPERATIONS.md** for the per-stack update procedures and the
before/after checklist.

```
== 40-jenkins-jobs: required dependencies (KUBECONFIG=/Users/zach/.kube/kind-jenkins.yaml)

[ OK ]      cli: terraform                   /opt/homebrew/bin/terraform
[ OK ]      cli: kubectl                     /opt/homebrew/bin/kubectl
[ OK ]      cli: python3                     /opt/homebrew/bin/python3
[ OK ]      state: 00-cluster                /Users/zach/demooct2026/state/00-cluster.tfstate
[ OK ]      state: 30-jenkins                /Users/zach/demooct2026/state/30-jenkins.tfstate
[ OK ]      cluster reachable                kind-jenkins
[ OK ]      namespace: jenkins               
[ OK ]      helm release: jenkins/jenkins    deployed
[ OK ]      pod/jenkins-0 (ns jenkins)       Ready
[ OK ]      configmap/jenkins-global-env (ns jenkins) 
[ OK ]      config-reload sidecar            jobs ConfigMaps will be hot-reloaded
[ OK ]      plugin: job-dsl                  
[ OK ]      plugin: configuration-as-code    
[ OK ]      plugin: workflow-aggregator      
[ OK ]      plugin: kubernetes               
[ OK ]      agent template envFrom           jenkins-agent-global-vars referenced
[UNHEALTHY] jenkins/globalVars.yaml          must be a flat map of scalar values with env-var-safe keys (or PyYAML missing: pip install pyyaml)
[ OK ]      http http://localhost:8080/login HTTP 200
[ OK ]      node jenkins-worker2 (role=jenkins-agent) Ready

0 missing, 1 unhealthy. Resolve the items above before applying this stack.

kubectl -n jenkins get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo


```

To inspect your **kind** (Kubernetes in Docker) clusters, you use a combination of the `kind` CLI (to list the clusters/containers themselves) and `kubectl` (to inspect the Kubernetes state inside them).

### 1. List All `kind` Clusters and Nodes

Before running `kubectl`, check which `kind` clusters exist on your machine:

```bash
# List all running kind cluster names
kind get clusters

# List the Docker container "nodes" for a specific cluster (default name is "kind")
kind get nodes --name <cluster-name>

```

---

### 2. Get Cluster Endpoint Info for All `kind` Clusters

By default, `kind` prefixes cluster contexts with `kind-` (for example, a cluster named `dev` has the context `kind-dev`).

**For a single cluster:**

```bash
kubectl cluster-info --context kind-<cluster-name>

```

**Loop through all `kind` clusters at once (Bash/Zsh):**

```bash
for cluster in $(kind get clusters); do
  echo "=== Cluster: $cluster ==="
  kubectl cluster-info --context "kind-$cluster"
  kubectl get nodes --context "kind-$cluster" -o wide
  echo ""
done

```

---

### 3. Get All Resources Inside a Cluster

If you want to see everything running inside your active `kind` cluster across all namespaces:

```bash
# Get common workload resources (Pods, Services, DaemonSets, Deployments, ReplicaSets) across all namespaces
kubectl get all --all-namespaces

# Shortened flag version (with node/IP details)
kubectl get all -A -o wide

```

> **Note on `kubectl get all`:** Despite the name, `kubectl get all` intentionally excludes ConfigMaps, Secrets, Ingresses, PVCs, and Nodes. To inspect those alongside workloads, run:
> ```bash
> kubectl get nodes,all,ing,pvc,cm,secret -A
> 
> ```
> 
> 

---

### 4. Full Diagnostic State Dump

If you are troubleshooting a broken cluster and literally need **all** cluster logs, events, and resource states exported:

```bash
# Dump full cluster state and pod logs to the terminal
kubectl cluster-info dump

# Or save the entire dump cleanly into a folder
kubectl cluster-info dump --all-namespaces --output-directory=./kind-cluster-dump

```

---

### Quick Reference Table

| Goal | Command |
| --- | --- |
| **List all local `kind` clusters** | `kind get clusters` |
| **See all `kubectl` contexts** | `kubectl config get-contexts` |
| **Switch active `kind` cluster** | `kubectl config use-context kind-<cluster-name>` |
| **View control plane & CoreDNS URLs** | `kubectl cluster-info` |
| **View node status & IPs** | `kubectl get nodes -o wide` |
| **View all workloads in all namespaces** | `kubectl get all -A` |