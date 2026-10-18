# Pros and Cons: Breaking Out Terraform into Modular Stages

**Context:** Moving from a single monolithic Terraform configuration to independent root modules (stacks) that communicate via `terraform_remote_state`, as demonstrated in https://github.com/zach2017/demooct2026.

This document incorporates patterns from:
- OpenCredo’s progressive evolution model (Terralith → Multi-Terralith → Terramod → Terraservices)
- HashiCorp multi-cloud Kubernetes tutorial practices
- Multi-environment state isolation best practices

---

## Mapping to Established Patterns

OpenCredo describes a common evolution path observed across client engagements:

| Stage | Description | State Model | Risk Profile |
|-------|-------------|-------------|--------------|
| **Terralith** | Single file/config managing all environments | One local state | High (cross-env accidents) |
| **Multi-Terralith** | Separate directories per environment | One state per environment | Medium (duplication remains) |
| **Terramod** | Reusable modules composed by environment | Still one state per environment | Medium-low |
| **Terraservices** | Independent components (one state per component per environment) | Remote state + `terraform_remote_state` | Low |

The staged root-module approach used in the demo repository is essentially **Terraservices**: each logical layer (cluster, nodes, Istio, Jenkins controller, jobs) is an independent root module with its own state. This is the same pattern shown in HashiCorp’s multi-cloud Kubernetes tutorial, where EKS, AKS, Consul, and the application each live in separate directories and share data only through remote state.

---

## Pros

### 1. Independent Apply / Destroy and Smaller Blast Radius
- You can re-apply or destroy one layer (e.g., only the Jenkins jobs stack) without touching the cluster, Istio, or the Jenkins controller.
- A bad change in jobs or agent environment variables does not force a Helm upgrade or controller restart.
- Destroy guards can refuse to destroy an upstream stack while downstream state still exists, preventing orphaned resources or accidental cluster destruction.
- Aligns with Terraservices goal of isolating change impact (a bastion or networking change no longer risks the Kubernetes control plane).

### 2. Faster Iteration and Targeted Upgrades
- Changing a Jenkinsfile or `globalVars.yaml` only requires applying the jobs stack (~seconds to a minute).
- Plugin or chart version bumps stay isolated to the Jenkins stack.
- Teams can own different layers (platform team owns cluster/Istio, app team owns jobs) with less coordination — the same multi-team benefit OpenCredo observed when moving to Terraservices.

### 3. Clear Dependency Boundaries and Explicit Data Flow
- Each stack declares exactly what it needs from upstream via `terraform_remote_state`.
- Outputs become a contract. Changing an output that downstream stacks consume is visible in plans.
- Matches the HashiCorp multi-cloud tutorial pattern: cluster directories expose outputs; the Consul and application directories consume them via remote state rather than sharing a single state file.
- Easier to reason about “what depends on what.”

### 4. Better State Isolation and Recovery
- Separate state files mean a corrupted or locked state affects only one layer.
- You can `terraform state` operations or migrate individual stacks more safely.
- Local backend files (as in the demo) are simple to back up or inspect; production should move to remote backends with versioning and locking (S3 + DynamoDB, Terraform Cloud, etc.).
- Multi-environment best practice: isolate state per environment *and* per component rather than relying solely on workspaces when components have different lifecycles.
- Supports the immutability-oriented recovery patterns described for multi-cluster Rancher/RKE setups (provision new nodes, restore from state-stored configuration, re-import).

### 5. Improved CI/CD and Reviewability
- Pull requests can be scoped to a single stack.
- Plans are smaller and easier to review.
- Automated checks (the per-stack `check-deps.sh` scripts) can validate prerequisites before apply.
- Provider aliasing (as used in the multi-cloud tutorial) remains available inside a single stack when one configuration must talk to multiple clusters.

### 6. Modular Upgrades and Versioning
- You can upgrade Istio, the Jenkins chart, or the kind cluster independently (respecting compatibility windows).
- Rollbacks are narrower: roll back one stack’s state/code without reversing everything.

### 7. Reusability and Composition
- Individual stacks can later be extracted into reusable modules or shared across environments with only backend/path changes.
- The same pattern scales to multiple environments (dev/staging/prod) with different variable sets.
- Complements module-based composition (Terramod) — stages can themselves call shared modules while remaining independently stateful.

---

## Cons

### 1. Increased Operational Complexity
- Developers must understand the apply order and the remote-state contract.
- More files, more directories, and more moving parts than a single `main.tf`.
- New team members have a steeper learning curve.
- OpenCredo notes that Terraservices increases orchestration needs; dependency ordering must be documented or automated (Makefile, Terragrunt, or CI).

### 2. State Management Overhead
- Multiple state files must be stored, backed up, and access-controlled.
- Local backends are convenient for demos but not suitable for teams; remote backends (S3, Terraform Cloud, etc.) add setup and cost.
- State drift between stacks can occur if someone applies them out of order or manually edits resources.
- Best practice from multi-environment guidance: prefer separate directories + remote backends with encryption, locking, and versioning over workspaces when isolation is critical. Never commit secrets or state to Git.

### 3. Dependency Ordering and Coordination
- Downstream stacks fail if upstream state is missing or outdated.
- Cross-stack changes (e.g., renaming an output or changing a node selector) require coordinated re-applies of every dependent stack.
- Circular dependencies are harder to introduce but also harder to detect early.
- Matches the multi-cloud tutorial’s use of explicit remote-state data sources and `depends_on` where needed.

### 4. Potential for Inconsistency
- Two stacks can get out of sync (e.g., Jenkins Helm values expect a ConfigMap that the jobs stack has not yet created).
- Optional references (like the agent global vars ConfigMap) help, but not every dependency can be optional.
- Destroy order must be strictly reverse of apply order; forgetting this leaves orphaned objects.

### 5. Tooling and Automation Burden
- A Makefile (or equivalent CI pipeline) is almost required to enforce ordering, run dependency checks, and handle migration.
- Destroy guards and pre-apply checks must be maintained; they are easy to get wrong.
- Debugging “which stack owns this resource?” requires more knowledge.
- For multi-cluster scenarios, provider aliases and careful credential passing (as shown in the HashiCorp multi-cloud tutorial) add further configuration surface.

### 6. Slightly Higher Runtime Cost
- Each `terraform apply` still has to initialize providers and read remote state.
- For very small changes the overhead of multiple stacks can feel higher than a single plan (though the actual cloud changes are smaller).

### 7. Migration Cost
- Moving an existing monolithic configuration into stages requires careful state splitting (`terraform state mv`, separate state files, or `terraform init -migrate-state`).
- During the transition there is risk of duplicate resources or lost state.
- DR scenarios (as described in the Redapt multi-cluster Rancher case) may require additional state import/push scripts when clusters are rebuilt.

---

## Summary Table

| Aspect | Monolithic (Terralith) | Staged / Modular (Terraservices) |
|--------|------------------------|----------------------------------|
| Blast radius of a change | Large | Small |
| Speed of iterating on jobs/env | Slow (full apply) | Fast (single stack) |
| State isolation | Single point of failure | Good (per component) |
| Operational complexity | Low | Higher |
| Team ownership | Harder | Easier |
| Upgrade flexibility | Coupled | Independent (with care) |
| Learning curve | Lower | Higher |
| Best for | Small, simple environments | Medium-to-large or frequently changing platforms |
| Multi-environment safety | Weak | Strong (separate states) |

---

## When Modular Stages Win

- The platform has distinct layers with different change frequencies (cluster rarely, jobs daily).
- Multiple people or teams touch the code.
- You want to destroy or re-create one layer without a full rebuild.
- You already have (or are willing to invest in) automation for ordering, checks, and guards.
- You manage multiple clusters or environments and need the isolation shown in HashiCorp’s multi-cloud and multi-environment guidance.

## When a Monolith Is Still Fine

- Single-person project or very small environment.
- Everything changes together and is applied infrequently.
- Team has limited Terraform experience and prefers simplicity.

The demo repository shows a well-engineered middle ground: five focused stacks, explicit remote-state contracts, destroy guards, and dependency checks. That combination captures most of the pros while mitigating many of the cons, and aligns with the Terraservices pattern recommended for mature teams.