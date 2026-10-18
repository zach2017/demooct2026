# Apply / destroy the stacks in dependency order. Each stack keeps its own
# terraform.tfstate in its directory.
STACKS := 00-cluster 10-nodes 20-istio 30-jenkins 40-jenkins-jobs
TF     ?= terraform

.PHONY: init plan apply destroy check $(STACKS) output

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
