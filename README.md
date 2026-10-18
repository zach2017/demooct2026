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
src/                             sample Dockerfile with __HELLO_IMAGE__:__HELLO_IMAGE_TAG__ placeholders
scripts/wait-for-jenkins.sh      prints pod/container/event/log status while Jenkins starts
scripts/diagnose.sh              one-shot dump of everything
scripts/guard-destroy.sh         destroy guard run by each stack's terraform_data.destroy_guard
OPERATIONS.md                    how to update each stack, what to re-apply, destroy guards
Makefile                         apply/destroy all stacks in order
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

The `hello` job reads `HELLO_IMAGE`/`HELLO_IMAGE_TAG`, replaces the placeholders in
`src/Dockerfile`, fails if any survive, and archives the result.

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
| `init  waiting ... BackOff`, `[init prev] <plugin> requires a greater version of Jenkins` | image older than current plugins need | bump `jenkins_image_tag` to the current LTS (https://www.jenkins.io/changelog-stable/) |
| `init  waiting ImagePullBackOff` | can't pull from Docker Hub | check Docker network/proxy |
| `init  running` for minutes, log stuck on a URL | plugin download blocked | keep `jenkins_controller_sidecar=false`; check host egress |
| `jenkins running restarts=N`, `Startup probe failed` | slow first boot | raise `probes.startupProbe.failureThreshold` in values |
| `[jenkins] ConfiguratorException` | JCasC YAML rejected | the message names the key |
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
