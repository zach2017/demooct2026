# Proposal: Migrating from Monolithic Terraform to Staged Root Modules

**Goal:** Move from a single Terraform root module that manages the entire platform (cluster + Istio + Jenkins + jobs) to a set of independent, ordered root modules (stages) that communicate via `terraform_remote_state`.

**Reference implementation:** https://github.com/zach2017/demooct2026

This proposal draws on:
- OpenCredo’s evolutionary model (Terralith → Multi-Terralith → Terramod → Terraservices)
- HashiCorp multi-cloud Kubernetes tutorial (separate directories + remote state)
- Multi-environment state and secrets isolation practices

---

## 1. Why Stage the Configuration?

A monolithic configuration (Terralith) forces every change—whether a new Jenkinsfile, a chart version bump, or an Istio egress rule—through the same plan and state. This creates:

- Large blast radius
- Long plan/apply times
- Tight coupling between layers that change at different rates
- Difficult ownership and review
- High risk of cross-environment accidents

Staging (Terraservices) isolates change frequency, enables independent upgrades, and provides clear contracts between layers while preserving the ability to apply or destroy a single layer safely. This is the same isolation pattern used in HashiCorp’s multi-cloud Kubernetes tutorial and recommended for multi-team environments.

---

## 2. Target Architecture

```
stacks/
  00-cluster/        kind / EKS / GKE cluster, kubeconfig, base networking
  10-nodes/          node pools, labels, taints, roles
  20-istio/          Istio base, istiod, gateways, ServiceEntries
  30-jenkins/        namespace, Helm release, global env ConfigMap, ingress
  40-jenkins-jobs/   Job ConfigMaps (JCasC), agent-only env, sample sources
```

**Communication pattern**
- Each stack is a root module with its own state file (`state/<stack>.tfstate` or remote backend path).
- Downstream stacks read upstream outputs exclusively through `terraform_remote_state`.
- No direct resource references across stack boundaries.
- Provider aliases can be used inside a stack when it must talk to multiple clusters (as demonstrated in the multi-cloud tutorial).

**Supporting automation**
- Makefile (or CI pipeline) that applies in order and destroys in reverse order.
- Per-stack `check-deps.sh` scripts that verify upstream state and live cluster health.
- Destroy guards (`terraform_data` + local-exec) that refuse to destroy a stack while downstream resources still exist.

**State backend recommendation**
- Development: local backends are acceptable.
- Production / team use: remote backends (S3 + DynamoDB locking, Terraform Cloud, or equivalent) with encryption, versioning, and access controls. Never store secrets in state or commit state to Git. Prefer separate state per component *and* per environment over workspaces when lifecycles differ.

---

## 3. Recommended Stages (Generalized)

| Stage | Owns | Changes frequently? | Typical consumers |
|-------|------|---------------------|-------------------|
| 00-foundation | VPC, cluster, IAM, base networking | Rarely | Everything |
| 10-platform | Node pools, storage classes, core operators | Occasionally | Apps |
| 20-mesh / networking | Istio / service mesh, gateways, network policies | Occasionally | Apps |
| 30-control-plane-app | Jenkins / Argo / etc. controller, global config | Moderately | Jobs / workloads |
| 40-workloads | Jobs, pipelines, application ConfigMaps, agent env | Daily | End users |

Adjust the split to match your change frequency and team boundaries. The key is that each stage has a single, clear responsibility and a stable set of outputs. This mirrors the component directories (eks, aks, consul, application) in the HashiCorp multi-cloud tutorial.

---

## 4. Migration Plan

### Phase 0 – Preparation (1–2 days)
1. Inventory the current monolithic configuration: list every resource and the layer it belongs to.
2. Define the desired output contracts for each future stage.
3. Choose state backend strategy (local for experiment, remote with locking/encryption for production).
4. Create the directory structure and a skeleton Makefile.
5. Document the evolutionary rationale (moving from Terralith toward Terraservices) for stakeholders.

### Phase 1 – Extract the Foundation (00)
1. Move cluster, kubeconfig, and base networking resources into `stacks/00-cluster`.
2. Expose necessary outputs (endpoint, certificates, kubeconfig path, node names, etc.).
3. Use `terraform state mv` (or a new apply + import) to move resources into the new state file.
4. Verify the new stack applies cleanly and produces the expected outputs.
5. Leave a thin “bridge” in the old configuration that reads the new remote state (or temporarily duplicate) until later phases.

### Phase 2 – Extract Subsequent Stages
Repeat for each stage, working from the bottom up or in dependency order:
1. Create the new root module.
2. Move resources and rewrite any cross-references to use `terraform_remote_state`.
3. Migrate state.
4. Update the previous stage’s outputs if needed.
5. Run the new stage’s `check-deps` and apply.
6. Confirm downstream behavior still works.

**Recommended order for the Jenkins example:**
1. 00-cluster
2. 10-nodes
3. 20-istio
4. 30-jenkins
5. 40-jenkins-jobs

### Phase 3 – Add Safety Nets
1. Implement destroy guards for every stage.
2. Write and wire per-stack dependency check scripts.
3. Update CI to use the ordered Makefile targets.
4. Document the apply/destroy order and the output contracts (see OPERATIONS.md style).
5. Add backend encryption, locking, and versioning; ensure secrets are passed via variables or external secret stores rather than hardcoded.

### Phase 4 – Cut Over and Clean Up
1. Once all stages are live and verified, remove the old monolithic configuration.
2. Run a full destroy (with guards) in a non-production environment to validate the reverse order.
3. Update runbooks and onboarding docs.
4. Archive the old state file.
5. For multi-cluster or DR scenarios, prepare state import/push procedures similar to those used in the Redapt Rancher recovery workflow.

---

## 5. State Migration Techniques

| Technique | When to use | Risk |
|-----------|-------------|------|
| `terraform state mv` + new backend | Resources already exist and you want zero downtime | Medium – careful addressing required |
| Fresh apply + import | Small number of critical resources | Lower for simple resources |
| Parallel run + switch | You can afford temporary duplication | Higher cost, lowest risk |
| `terraform init -migrate-state` | Moving an existing state file into the new path | Low if done one stack at a time |

Always take a state backup before any migration. Prefer remote backends with versioning so you can roll back state independently of code.

---

## 6. Success Criteria

- [ ] Each stage can be applied independently after its upstream dependencies exist.
- [ ] Changing a job or agent environment variable requires only the jobs stage.
- [ ] Destroying a stage is refused while any downstream stage still has state.
- [ ] Full `make apply` and `make destroy` succeed end-to-end.
- [ ] Plans for a single stage are small and reviewable.
- [ ] New team members can add a job by editing one directory and running one make target.
- [ ] State is isolated per component (and per environment if applicable), stored remotely with locking and encryption, and contains no plaintext secrets.

---

## 7. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| State split errors leave resources unmanaged | Take backups; use `terraform state list` before/after; test in a disposable environment |
| Output contract changes break downstream | Version outputs or use intermediate variables; require plan review on upstream changes |
| Developers apply stages out of order | Makefile + CI enforcement; `check-deps.sh` fails fast |
| Local state files are lost | Move to remote backend early; encrypt and version state |
| Destroy guards are incomplete | Regularly run `make check`; add new guards when new cross-stack dependencies appear |
| Secrets leak into state | Pass secrets via variables or external stores (Vault, etc.); enable backend encryption; audit state |
| Multi-cluster credential or DR complexity | Use provider aliases; document import/push procedures; store recoverable configuration in state as shown in multi-cluster case studies |

---

## 8. Timeline Estimate

| Phase | Effort | Calendar (1 person) |
|-------|--------|---------------------|
| Preparation + inventory | 1–2 days | Day 1–2 |
| Extract 00–20 (foundation + mesh) | 2–3 days | Day 3–5 |
| Extract 30–40 (Jenkins + jobs) | 1–2 days | Day 6–7 |
| Guards, checks, docs, CI | 1–2 days | Day 8–9 |
| Validation & cut-over | 1 day | Day 10 |

Total: approximately 1–2 weeks for a platform the size of the reference repository. Larger existing codebases will take longer, mainly in the inventory and state-move phases.

---

## 9. Recommendation

Proceed with the staged (Terraservices-style) model. The reference implementation already proves that the pattern works for a realistic Jenkins-on-Istio-on-kind setup, including hot-reload of jobs and agent environment variables. The investment in ordering automation and destroy guards pays for itself the first time someone needs to update a pipeline without restarting the controller or re-creating the cluster.

This approach aligns with industry patterns from OpenCredo, HashiCorp’s multi-cloud tutorials, and multi-environment state isolation guidance. Start with a non-production environment, migrate one stage at a time, move to a remote backend with locking and encryption as soon as more than one person is involved, and keep the old configuration available until the full ordered apply/destroy cycle is proven.