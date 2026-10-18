# Apply / destroy the stacks in dependency order. Each stack keeps its own
# state file under state/<stack>.tfstate (local backend).
STACKS := 00-cluster 10-nodes 20-istio 30-jenkins 40-jenkins-jobs
TF     ?= terraform

.PHONY: init plan apply destroy check migrate-state $(STACKS) output

init:
	@for s in $(STACKS); do echo "== $$s"; $(TF) -chdir=stacks/$$s init -upgrade -input=false; done

apply:
	@for s in $(STACKS); do echo "== apply $$s"; $(TF) -chdir=stacks/$$s apply -auto-approve -input=false || exit 1; done

plan:
	@for s in $(STACKS); do echo "== plan $$s"; $(TF) -chdir=stacks/$$s plan -input=false; done

# reverse order; each stack's guard refuses if anything still depends on it
REVERSE := $(shell echo $(STACKS) | tr ' ' '\n' | sort -r | tr '\n' ' ')
destroy:
	@for s in $(REVERSE); do \
	  echo "== destroy $$s"; \
	  scripts/guard-destroy.sh $$s || exit 1; \
	  $(TF) -chdir=stacks/$$s destroy -auto-approve -input=false || exit 1; done

# destroy one stack: make destroy-30-jenkins   (FORCE_DESTROY=1 to bypass the guard)
destroy-%:
	scripts/guard-destroy.sh $* && $(TF) -chdir=stacks/$* destroy -input=false

# dry run of all guards: shows what would block each stack
check:
	@for s in $(REVERSE); do echo "== $$s"; scripts/guard-destroy.sh $$s || true; done

# apply a single stack: make 30-jenkins
$(STACKS):
	$(TF) -chdir=stacks/$@ init -input=false >/dev/null && $(TF) -chdir=stacks/$@ apply -input=false

output:
	@echo "KUBECONFIG=$$($(TF) -chdir=stacks/00-cluster output -raw kubeconfig_path)"
	@echo "URL=$$($(TF) -chdir=stacks/30-jenkins output -raw jenkins_url)"
	@echo "PASSWORD=$$($(TF) -chdir=stacks/30-jenkins output -raw jenkins_admin_password)"

# One-time: move state created by the old layout (stacks/<s>/terraform.tfstate)
# into state/<s>.tfstate. Safe to re-run; skips stacks with nothing to move.
migrate-state:
	@mkdir -p state
	@for s in $(STACKS); do \
	  if [ -f stacks/$$s/terraform.tfstate ]; then \
	    echo "== $$s: migrating"; \
	    $(TF) -chdir=stacks/$$s init -migrate-state -force-copy -input=false >/dev/null && \
	    rm -f stacks/$$s/terraform.tfstate stacks/$$s/terraform.tfstate.backup && echo "   -> state/$$s.tfstate"; \
	  fi; done
	@ls -1 state/*.tfstate 2>/dev/null || echo "no state files yet"
