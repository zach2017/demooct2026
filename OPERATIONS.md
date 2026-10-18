# Operations: updating and destroying each stack

Stacks depend on each other top-down. Any change you make must respect that
order: **apply from the changed stack downward, destroy from the bottom up.**

```
00-cluster ─▶ 10-nodes ─▶ 30-jenkins ─▶ 40-jenkins-jobs
           └▶ 20-istio ─┘
```

Rule of thumb for every change:

1. `terraform -chdir=stacks/<stack> plan` — read what will be replaced vs. updated in place.
2. If anything is **replaced** (`-/+`), everything below it that reads those outputs must be re-applied afterwards.
3. `make check` before any destroy; the guards tell you what would block.

## Destroy guards

Every stack has a `terraform_data.destroy_guard` whose destroy-time provisioner
runs `scripts/guard-destroy.sh`. Because the guard depends on every other
resource in its stack, Terraform destroys it **first**; when the script exits
non-zero the whole destroy aborts before any real resource is touched.

What each guard refuses on, and the command it prints to show you the blocker:

| Destroying | Refused when | Shown by |
|---|---|---|
| `00-cluster` | any later stack still has managed resources in its state | `terraform -chdir=stacks/<n> state list` |
| | `istio-system` or `jenkins` namespace still exists | `kubectl get all -n <ns>` |
| `10-nodes` | `30-jenkins`/`40-jenkins-jobs` have state | state list |
| | workload pods are scheduled on a role-labelled node | `kubectl get pods -A --field-selector spec.nodeName=<node>` |
| `20-istio` | `30-jenkins`/`40-jenkins-jobs` have state | state list |
| | a namespace is labelled `istio-injection=enabled` | `kubectl get ns -l istio-injection=enabled` |
| | `Gateway`/`VirtualService` objects exist outside `istio-system` | `kubectl get gateway,virtualservice -A` |
| `30-jenkins` | `40-jenkins-jobs` has state | state list |
| | job ConfigMaps (label `jenkins-jenkins-config=true`) are present | `kubectl get cm -n jenkins -l jenkins-jenkins-config=true` |
| | build agent pods are running | `kubectl get pods -n jenkins -l jenkins/label=jenkins-jenkins-agent` |
| `40-jenkins-jobs` | build agent pods are running | same |

Example of a refused destroy:

```
$ terraform -chdir=stacks/20-istio destroy
terraform_data.destroy_guard: Destroying...
terraform_data.destroy_guard: Provisioning with 'local-exec'...
BLOCKED: stack 30-jenkins still has resources in its state and depends on 20-istio.
  see:    terraform -chdir=/…/stacks/30-jenkins state list
  fix:    terraform -chdir=/…/stacks/30-jenkins destroy     (destroy downstream first)
BLOCKED: namespace(s) with istio-injection=enabled: jenkins  — their pods carry sidecars from istiod.
  see:    kubectl get ns -l istio-injection=enabled
  fix:    terraform -chdir=/…/stacks/30-jenkins destroy
guard-destroy: refusing to destroy 20-istio. Override with FORCE_DESTROY=1 if you really mean it.
│ Error: local-exec provisioner error … exit status 1
```

Nothing was destroyed. Fix the blocker, or `FORCE_DESTROY=1 terraform destroy`
if you accept orphaned objects (e.g. the cluster is already gone).

`make destroy` runs the guard for each stack before calling Terraform, so the
same checks apply; `make check` runs all guards without destroying anything.

## Updating each stack

### 00-cluster (kind)

| Change | Effect | Before | After |
|---|---|---|---|
| `worker_count` | **replaces the cluster** (kind can't add nodes) | `make destroy` everything | `make apply` everything |
| `kind_node_image` | replaces the cluster | same | same |
| `ingress_*_host_port` | replaces the cluster (port maps are in kind config) | same | same |
| `kubeconfig_path` | replaces the cluster | same | same |

There is no in-place change to this stack; treat any edit as a rebuild.
Verify: `docker ps --filter name=jenkins-`, `kubectl get nodes`.

### 10-nodes (labels/taints)

| Change | Effect | Before | After |
|---|---|---|---|
| which worker is the controller (`local.controller_node`) | label/taint updated in place; **running pods are not moved** | drain is not needed for taints, but Jenkins will not reschedule by itself | `make 30-jenkins` (re-render selectors) then `kubectl -n jenkins delete pod jenkins-0` to move it; watch `kubectl get pods -n jenkins -o wide` |
| taint key/value | pods on that node keep running until restarted | — | restart affected pods |

Verify: `kubectl get nodes -L role` and
`kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints[*].key`.

### 20-istio

| Change | Effect | Before | After |
|---|---|---|---|
| `istio_version` | Helm upgrades base → istiod → gateways; sidecars keep the **old** proxy until their pods restart | read the Istio upgrade notes for skip-version limits (only one minor at a time) | `kubectl -n jenkins rollout restart statefulset/jenkins` only if the controller has a sidecar; agent pods pick up the new proxy on their next build |
| `egress_hosts` | ServiceEntry/Gateway/VirtualService updated in place | — | nothing; sidecars receive config from istiod within seconds. Verify with `istioctl proxy-config listener <agent-pod> -n jenkins` |
| `outboundTrafficPolicy` → `REGISTRY_ONLY` | immediately blocks every unlisted host from sidecar pods | add all hosts the jobs need to `egress_hosts` (e.g. registries, plugin mirrors) | run the `hello` job and check `[init]`/agent logs for `connection reset` |
| gateway NodePorts | must stay 30080/30443; they are hard-wired in 00-cluster | — | — |

Verify: `kubectl -n istio-system get pods`, `istioctl version`, `curl -sI localhost:8080/login`.

### 30-jenkins

| Change | Effect | Before | After |
|---|---|---|---|
| `global_env` | ConfigMap updated **and** JCasC reloaded (chart config-reload sidecar) | — | new env is live for new builds within ~30 s. Running builds keep the old values. Verify: `kubectl -n jenkins get cm jenkins-global-env -o yaml`, and in Jenkins *Manage → System → Global properties* |
| `jenkins_image_tag` / `jenkins_chart_version` | Helm upgrade, **controller pod restarts** (StatefulSet) | finish or abort running builds (`kubectl get pods -n jenkins -l jenkins/label=jenkins-jenkins-agent` should be empty) | the startup watcher streams progress; jobs from 40 are re-seeded automatically on reload |
| `installPlugins` in `values.yaml.tftpl` | controller restart | same as above; keep `jenkins_image_tag` a current LTS or the init container fails with `requires a greater version of Jenkins` | check `kubectl -n jenkins logs jenkins-0 -c init` |
| `jenkins_controller_sidecar` | controller restart, pod gets/loses `istio-proxy` | 20-istio must be applied | `kubectl -n jenkins get pod jenkins-0 -o jsonpath='{.spec.initContainers[*].name}'` should list `istio-proxy` |
| `jenkins_sidecar_injection` | namespace label change; **existing pods unaffected** | — | agent pods are fresh per build, so nothing to restart; controller: see row above |
| `jenkins_host` | Gateway + VirtualService updated in place | add the hostname to `/etc/hosts` → 127.0.0.1 | `curl -sI -H "Host: <host>" localhost:8080/login` |
| `jenkins_admin_password` | Secret updated; chart does **not** rewrite an existing admin user | — | change it in the Jenkins UI too, or delete the PVC to re-init (loses job history) |

Verify after any change: `kubectl -n jenkins get pods`, `scripts/wait-for-jenkins.sh ~/.kube/kind-jenkins.yaml jenkins 300 /tmp/j.log`.

### 40-jenkins-jobs

| Change | Effect | Before | After |
|---|---|---|---|
| add a job (`jenkins/jobs/<name>.Jenkinsfile` + `local.jobs` entry) | new ConfigMap; config-reload sidecar triggers a JCasC reload, Job DSL creates the job | 30-jenkins must be Ready | job visible in ~30 s. Verify: `kubectl -n jenkins logs jenkins-0 -c config-reload --tail=20` and the Jenkins job list |
| edit a Jenkinsfile | ConfigMap updated, job definition replaced; **running builds finish with the old script** | — | next build uses the new script |
| remove a job | ConfigMap deleted; Job DSL **does not delete** jobs on its own (`removedJobAction` defaults to IGNORE) | — | delete it in the UI or set `removedJobAction('DELETE')` in `job.yaml.tftpl` |
| `src/Dockerfile`, `src/hello.sh` | `hello-src` ConfigMap updated; agent pods mount it fresh on every build | — | nothing |

A job ConfigMap with invalid JCasC/Job DSL does not break the controller; the
reload fails and the previous config stays active. Look at
`kubectl -n jenkins logs jenkins-0 -c jenkins | grep -i -E 'casc|dsl'`.

## Cross-stack change checklist

| You changed… | Re-apply afterwards |
|---|---|
| `00-cluster` (anything) | `10-nodes`, `20-istio`, `30-jenkins`, `40-jenkins-jobs` — all outputs (endpoint, certs) changed |
| `10-nodes` node roles | `30-jenkins` (selectors), then restart `jenkins-0` |
| `20-istio` ingress gateway selector / namespace | `30-jenkins` (Gateway selector) |
| `30-jenkins` namespace or release name | `40-jenkins-jobs` (namespace + ConfigMap label) |
| `30-jenkins` anything else | nothing; 40's ConfigMaps are picked up again on reload |

Terraform will not tell you a downstream stack is stale — `terraform_remote_state`
is read at plan time of the *downstream* stack. Run `make plan` after any
upstream change to see what moved.

## Recovery

- Helm release stuck in `failed`: `helm -n jenkins uninstall jenkins` then `make 30-jenkins`.
- Downstream state references a cluster that no longer exists: `FORCE_DESTROY=1 terraform -chdir=stacks/<n> destroy` (the guard would otherwise insist on live checks it can't make), or `rm stacks/<n>/terraform.tfstate*` if you accept losing state.
- Guard false positive (e.g. a stuck Terminating pod): fix the object, or bypass with `FORCE_DESTROY=1`.
