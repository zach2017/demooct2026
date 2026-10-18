# Apply / destroy the stacks in dependency order. Each stack keeps its own
# state file under state/<stack>.tfstate (local backend).
#
# Every command this Makefile runs is printed before it executes, prefixed
# with a timestamp, and both the command line and its complete output are
# appended to a log file:
#
#     logs/make-<YYYYmmdd-HHMMSS>.log      one file per `make` invocation
#     logs/latest.log                      symlink to the newest one
#
# Override the log file with LOG=path, disable with LOG=/dev/null.

SHELL  := /usr/bin/env bash
.SHELLFLAGS := -eo pipefail -c

STACKS := 00-cluster 10-nodes 20-istio 30-jenkins 40-jenkins-jobs
REVERSE := $(shell echo $(STACKS) | tr ' ' '\n' | sort -r | tr '\n' ' ')
TF     ?= terraform
TFARGS ?= -input=false

RUN_ID := $(shell date +%Y%m%d-%H%M%S)
LOG    ?= logs/make-$(RUN_ID).log
export LOG

# ---- command runner ---------------------------------------------------------
# run <command...>: print it, log it, run it, log the output, keep exit status.
define run
	@mkdir -p "$(dir $(LOG))"; ln -sfn "$(notdir $(LOG))" "$(dir $(LOG))latest.log" 2>/dev/null || true
	@ts=$$(date '+%Y-%m-%d %H:%M:%S'); \
	  printf '\n\033[36m[%s] $$ %s\033[0m\n' "$$ts" '$(1)'; \
	  printf '\n[%s] $$ %s\n' "$$ts" '$(1)' >> "$(LOG)"
	@set +e; $(1) 2>&1 | tee -a "$(LOG)"; rc=$${PIPESTATUS[0]}; \
	  ts=$$(date '+%Y-%m-%d %H:%M:%S'); \
	  printf '[%s] exit=%s  (%s)\n' "$$ts" "$$rc" '$(1)' >> "$(LOG)"; \
	  if [ "$$rc" -ne 0 ]; then printf '\033[31m[%s] FAILED exit=%s: %s\033[0m\n' "$$ts" "$$rc" '$(1)'; fi; \
	  exit $$rc
endef

# section <title>: a banner in the terminal and the log
define section
	@mkdir -p "$(dir $(LOG))"
	@printf '\n\033[1m==== %s ====\033[0m\n' '$(1)'; printf '\n==== %s ====\n' '$(1)' >> "$(LOG)"
endef

.PHONY: help init plan apply destroy check deps migrate-state output log $(STACKS)
.PRECIOUS: logs/%

help:
	@echo "targets:"
	@echo "  make init              terraform init in every stack"
	@echo "  make plan              terraform plan in every stack"
	@echo "  make apply             check-deps + terraform apply, 00 -> 40"
	@echo "  make destroy           guard + terraform destroy, 40 -> 00"
	@echo "  make <stack>           check-deps + apply one stack, e.g. make 30-jenkins"
	@echo "  make destroy-<stack>   guard + destroy one stack"
	@echo "  make plan-<stack>      plan one stack"
	@echo "  make deps / deps-<s>   dependency checks only"
	@echo "  make check             destroy guards only (what would block)"
	@echo "  make migrate-state     move stacks/<s>/terraform.tfstate -> state/<s>.tfstate"
	@echo "  make output            KUBECONFIG / URL / PASSWORD"
	@echo "  make log               tail the latest log"
	@echo "  stacks: $(STACKS)"
	@echo "  log:    $(LOG)   (LOG=/dev/null to disable)"

# ---- all stacks -------------------------------------------------------------
init:
	$(call section,init all stacks)
	@for s in $(STACKS); do $(MAKE) --no-print-directory init-$$s LOG=$(LOG) || exit 1; done

plan:
	$(call section,plan all stacks)
	@for s in $(STACKS); do $(MAKE) --no-print-directory plan-$$s LOG=$(LOG) || exit 1; done

apply:
	$(call section,apply all stacks $(STACKS))
	@for s in $(STACKS); do $(MAKE) --no-print-directory $$s LOG=$(LOG) || exit 1; done
	$(call section,apply finished; log: $(LOG))

destroy:
	$(call section,destroy all stacks $(REVERSE))
	@for s in $(REVERSE); do $(MAKE) --no-print-directory destroy-$$s LOG=$(LOG) || exit 1; done
	$(call section,destroy finished; log: $(LOG))

deps:
	$(call section,dependency checks)
	@for s in $(STACKS); do $(MAKE) --no-print-directory deps-$$s LOG=$(LOG) || true; done

check:
	$(call section,destroy guards (dry run))
	@for s in $(REVERSE); do $(MAKE) --no-print-directory guard-$$s LOG=$(LOG) || true; done

guard-%:
	$(call run,scripts/guard-destroy.sh $*)

# ---- one stack --------------------------------------------------------------
# make 30-jenkins  ==  check-deps, init (quiet), apply
$(STACKS):
	$(call section,stack $@)
	$(call run,stacks/$@/check-deps.sh)
	$(call run,$(TF) -chdir=stacks/$@ init $(TFARGS))
	$(call run,$(TF) -chdir=stacks/$@ apply $(TFARGS) $(if $(AUTO),-auto-approve,))

init-%:
	$(call run,$(TF) -chdir=stacks/$* init -upgrade $(TFARGS))

plan-%:
	$(call run,$(TF) -chdir=stacks/$* plan $(TFARGS))

deps-%:
	$(call run,stacks/$*/check-deps.sh)

# make destroy-30-jenkins   (FORCE_DESTROY=1 to bypass the guard)
destroy-%:
	$(call section,destroy stack $*)
	$(call run,scripts/guard-destroy.sh $*)
	$(call run,$(TF) -chdir=stacks/$* destroy $(TFARGS) $(if $(AUTO),-auto-approve,))

# ---- utilities --------------------------------------------------------------
# One-time: move state created by the old layout into state/<s>.tfstate.
migrate-state:
	$(call section,migrate state files)
	@mkdir -p state
	@for s in $(STACKS); do \
	  if [ -f stacks/$$s/terraform.tfstate ]; then $(MAKE) --no-print-directory migrate-$$s LOG=$(LOG) || exit 1; fi; done
	$(call run,ls -1 state/)

migrate-%:
	$(call run,$(TF) -chdir=stacks/$* init -migrate-state -force-copy $(TFARGS))
	$(call run,rm -f stacks/$*/terraform.tfstate stacks/$*/terraform.tfstate.backup)

output:
	@echo "KUBECONFIG=$$($(TF) -chdir=stacks/00-cluster output -raw kubeconfig_path)"
	@echo "URL=$$($(TF) -chdir=stacks/30-jenkins output -raw jenkins_url)"
	@echo "PASSWORD=$$($(TF) -chdir=stacks/30-jenkins output -raw jenkins_admin_password)"

log:
	@ls -1t logs/make-*.log 2>/dev/null | head -5
	@echo "---- logs/latest.log ----"; tail -n 60 logs/latest.log 2>/dev/null || echo "no logs yet"
