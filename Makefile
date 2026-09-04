# ============================================================================
# IRC Fiber Infra — Blue/Green Deployments (repo root)
# ============================================================================
# There was never a Makefile here (nothing was deleted — git history has no
# root Makefile; `site/` is a submodule whose wrapper is site/Makefile).
# This file is the single entry point for zero-downtime deploys.
#
# Scope: GATEWAY ONLY (gateway + frontend). The engine (IRC daemon) holds
# TCP/TLS + JOIN state and deploys by hard restart BY DESIGN — see
# AGENTS.md "Engine Lifecycle". Do not blue/green the engine.
#
# Two fleets:
#   OVH prod (docker over ansible) — targets without prefix
#     make deploy-blue    # full: tag-prev → build → swap → verify
#     make swap           # swap only (image already built on host)
#     make rollback       # swap back to :blue-prev (health-checked)
#     make status|health|logs|engine-status
#   k3s dev (kubectl) — k8s-* targets
#     make k8s-deploy     # build+push :green → green Deployment → wait
#     make k8s-promote    # flip Service to green, park blue (replicas=0)
#     make k8s-rollback   # flip Service back to blue
#     make k8s-status|k8s-clean-green
#
# Overrides: TARGET=host  VAULT_PASS_FILE=path  GREEN_TAG=tag
#            KUBE_CONTEXT=ctx  KUBE_NS=ns  GREEN_IMAGE=img
# ============================================================================

.DELETE_ON_ERROR:
.DEFAULT_GOAL := help

# ----------------------------------------------------------------------------
# Variables — all ?= so callers can override per invocation
# ----------------------------------------------------------------------------
TARGET          ?= vps-efb4b52d
# Override with TARGET_SSH=... per invocation; else inventory, else fallback IP.
_SSH_HOST       = $(or $(TARGET_SSH),$(shell grep -m1 'ansible_host=' site/deploy/inventories/production/hosts.ini 2>/dev/null | sed -E 's/.*ansible_host=([^ ]+).*/\1/'),15.204.93.54)
# Relative to site/deploy (PLAY cd's there first); or pass an absolute path.
VAULT_PASS_FILE ?= .vault_pass.txt
SSH_KEY         ?= $(HOME)/.ssh/id_ed25519_ircfiber

KUBE_CONTEXT    ?= ubuntu-docker
KUBE_NS         ?= ircfiber
GREEN_TAG       ?= green
REGISTRY_HOST   ?= host.docker.internal:5000
GREEN_IMAGE     ?= $(REGISTRY_HOST)/ircfiber-gateway:$(GREEN_TAG)
BLUE_DEPLOY     ?= ircfiber-gateway
GREEN_DEPLOY    ?= ircfiber-gateway-green

# ----------------------------------------------------------------------------
# Helpers (recursive so TARGET_SSH resolves at use time)
# ----------------------------------------------------------------------------
SSH    = ssh -F /dev/null -o IdentitiesOnly=yes -i $(SSH_KEY) -o StrictHostKeyChecking=no deploy@$(_SSH_HOST)
PLAY   = cd site/deploy && ansible-playbook -l $(TARGET) --vault-password-file $(VAULT_PASS_FILE)
KUBECTL = kubectl --context $(KUBE_CONTEXT) -n $(KUBE_NS)

# Colors
R  := \033[0m
B  := \033[1m
D  := \033[2m
G  := \033[32m
Y  := \033[33m
C  := \033[36m
BG := \033[92m
OK := ✓
WR := ⚠
AR := →

# ----------------------------------------------------------------------------
# Help
# ----------------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@printf '\n$(B)IRC Fiber Infra — Blue/Green Deploys$(R) $(D)(gateway only; engine deploys by hard restart, see AGENTS.md)$(R)\n'
	@printf '$(D)============================================================$(R)\n'
	@printf '\n$(B)OVH prod (ansible/docker)$(R)\n'
	@awk 'BEGIN{FS=":.*##[ \t]*"} /^[a-zA-Z0-9_.-]+:.*##/{t=$$1; c=$$2; if (t !~ /^k8s/) {printf "  $(G)make %-*s$(R) %s\n", 18, t, c}}' $(MAKEFILE_LIST)
	@printf '\n$(B)k3s dev (kubectl)$(R)\n'
	@awk 'BEGIN{FS=":.*##[ \t]*"} /^k8s-[a-zA-Z0-9_.-]+:.*##/{printf "  $(C)make %-*s$(R) %s\n", 18, $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\n$(D)Defaults: TARGET=$(TARGET)  GREEN_TAG=$(GREEN_TAG)  KUBE_CONTEXT=$(KUBE_CONTEXT)/$(KUBE_NS)$(R)\n\n'

# ============================================================================
# OVH prod — ansible/docker blue/green (engine untouched)
# ============================================================================
.PHONY: deploy-blue deploy-engine deploy-ircd rehash-ircd tag-prev swap rollback status health logs engine-status

deploy-blue: tag-prev ## Full blue/green gateway deploy (tag-prev → build → swap → verify)
	@printf '\n$(BG)$(OK) Blue/green gateway deploy → $(TARGET) (engine untouched)$(R)\n'
	@$(MAKE) -C site -f Makefile.site update-gateway-bluegreen TARGET=$(TARGET) VAULT_PASS_FILE=$(VAULT_PASS_FILE)

# engine/deploy has no .vault_pass.txt — default to site's (absolute, since
# the sub-make cd's into engine/deploy). A CLI VAULT_PASS_FILE=... still wins.
_ENGINE_VAULT = $(if $(filter file,$(origin VAULT_PASS_FILE)),$(CURDIR)/site/deploy/.vault_pass.txt,$(VAULT_PASS_FILE))
deploy-engine: ## Engine deploy (hard restart, brief IRC reconnect — NOT zero-downtime)
	@printf '\n$(Y)$(WR) Engine deploy → $(TARGET) (hard restart, brief IRC disconnect)$(R)\n'
	@$(MAKE) -C engine -f Makefile.engine update TARGET=$(TARGET) VAULT_PASS_FILE=$(_ENGINE_VAULT)

tag-prev: ## Tag running gateway image as :blue-prev (rollback anchor)
	@printf '%b\n' "$(C)$(AR) tagging live gateway image → irc-fiber-gateway:blue-prev on $(TARGET)$(R)"
	@$(SSH) 'img=$$(sudo docker inspect -f "{{.Image}}" ircfiber-gateway 2>/dev/null) && sudo docker tag "$$img" irc-fiber-gateway:blue-prev && echo "blue-prev=$$img"'

swap: ## Swap only: run blue/green playbook (image already built on host)
	@printf '\n$(BG)$(OK) Blue/green swap → $(TARGET) (no build)$(R)\n'
	@$(SSH) 'sudo docker tag kevindpostal/irc-fiber-gateway:0.3.0 irc-fiber-gateway:latest 2>/dev/null || true'
	@$(PLAY) playbooks/caddy.yml 2>&1 | tail -5
	@$(PLAY) playbooks/gateway-bluegreen.yml 2>&1 | tail -15

rollback: ## Roll back gateway to :blue-prev image (health-checked swap, engine untouched)
	@printf '\n$(Y)$(WR) Rollback gateway → irc-fiber-gateway:blue-prev on $(TARGET)$(R)\n'
	@$(SSH) 'sudo docker inspect irc-fiber-gateway:blue-prev >/dev/null 2>&1 || { echo "✗ no :blue-prev image on host — deploy-blue tags it first"; exit 1; }'
	@$(PLAY) playbooks/gateway-bluegreen.yml -e ircfiber_gateway_image_full=irc-fiber-gateway:blue-prev 2>&1 | tail -15
	@printf '%b\n' "$(BG)$(OK) Rolled back to :blue-prev — verify: make health$(R)"

status: ## Remote container + deploy-hash status
	@$(PLAY) playbooks/status.yml 2>&1 | tail -20

health: ## Gateway /health + Caddy proxy check via playbook
	@$(PLAY) playbooks/healthcheck.yml 2>&1 | tail -15

logs: ## Tail remote gateway logs (last 100 lines)
	@$(PLAY) playbooks/logs.yml -e component=gateway tail=100 2>&1 | tail -30

engine-status: ## Prove engine untouched (PID + uptime, must not change across gateway deploys)
	@$(SSH) 'sudo docker exec ircfiber-engine-ovh pidof irc-fiber-engine | xargs -I {} echo "engine PID {}"; sudo docker ps --format "{{.Names}} {{.Status}}" | grep -E "engine"'

# --- IRCd (InspIRCd + Anope): config applies via SIGHUP rehash — listener
# and server sockets never drop. deploy-ircd re-renders configs from this
# repo first; rehash-ircd only signals (use when the host files are current).
deploy-ircd: ## Render ircd configs + SIGHUP rehash (no socket drops; only Anope restarts)
	@printf '\n$(BG)$(OK) IRCd deploy → $(TARGET) (rehash, sockets stay up)$(R)\n'
	@$(MAKE) -C site -f Makefile.site deploy-ircd TARGET=$(TARGET) VAULT_PASS_FILE=$(VAULT_PASS_FILE)

rehash-ircd: ## SIGHUP live ircd only, no repo push (exceptional: remote side fixed, nothing changed here)
	@printf '%b\n' "$(C)$(AR) rehashing ircfiber-ircd on $(TARGET)$(R)"
	@$(SSH) 'before=$$(sudo docker inspect -f "{{.State.StartedAt}}" ircfiber-ircd); sudo docker kill --signal=HUP ircfiber-ircd >/dev/null && sleep 3; after=$$(sudo docker inspect -f "{{.State.StartedAt}}" ircfiber-ircd); [ "$$before" = "$$after" ] && echo "OK rehashed, container not restarted (StartedAt $$after)" || { echo "✗ container restarted!"; exit 1; }; sudo docker logs --tail=5 ircfiber-ircd 2>&1 | grep -i -m1 "rehash\|config" || true'

# ============================================================================
# k3s dev — kubectl blue/green (Service selector flip, blue parked)
# ============================================================================
# Flow: k8s-deploy (green up alongside blue, no traffic) → verify →
# k8s-promote (Service → green, blue replicas=0, kept for rollback) →
# k8s-rollback flips back if needed. Green/blue share nothing: distinct
# Deployment names + distinct `app` labels, so no traffic split pre-promote.
.PHONY: k8s-deploy k8s-promote k8s-rollback k8s-status k8s-clean-green k8s-abort

k8s-deploy: ## Build+push GREEN_TAG, create green Deployment, wait ready (no traffic yet)
	@printf '\n$(C)$(AR) pushing $(GREEN_IMAGE)$(R)\n'
	@$(MAKE) -C site -f Makefile.k8s k8s-push-gateway --no-print-directory
	@docker tag $(REGISTRY_HOST)/ircfiber-gateway:dev $(GREEN_IMAGE) && docker push $(GREEN_IMAGE)
	@printf '%b\n' "$(C)$(AR) creating $(GREEN_DEPLOY) from live $(BLUE_DEPLOY) @ $(GREEN_IMAGE)$(R)"
	@$(KUBECTL) get deployment $(BLUE_DEPLOY) -o json | GREEN_DEPLOY="$(GREEN_DEPLOY)" GREEN_IMAGE="$(GREEN_IMAGE)" python3 -c \
		"import json,os,sys; d=json.load(sys.stdin); gd,gi=os.environ['GREEN_DEPLOY'],os.environ['GREEN_IMAGE']; \
		d['metadata']={'name':gd,'namespace':d['metadata'].get('namespace','ircfiber'),'labels':{'app':gd}}; \
		d['spec']['replicas']=1; d['spec']['selector']={'matchLabels':{'app':gd}}; \
		d['spec']['template']['metadata']={'labels':{'app':gd}}; \
		[c.update(image=gi) for c in d['spec']['template']['spec']['containers'] if c['name']=='gateway']; \
		d.pop('status',None); print(json.dumps(d))" | $(KUBECTL) apply -f -
	@$(KUBECTL) rollout status deployment/$(GREEN_DEPLOY) --timeout=120s
	@$(KUBECTL) exec deployment/$(GREEN_DEPLOY) -- curl -fsS http://127.0.0.1:8090/health >/dev/null \
		&& printf '%b\n' "$(BG)$(OK) green healthy, receiving NO traffic — promote: make k8s-promote$(R)"

k8s-promote: ## Flip Service to green, park blue at replicas=0 (kept for rollback)
	@printf '%b\n' "$(C)$(AR) flipping svc/$(BLUE_DEPLOY) → $(GREEN_DEPLOY)$(R)"
	@$(KUBECTL) patch svc $(BLUE_DEPLOY) -p '{"spec":{"selector":{"app":"$(GREEN_DEPLOY)"}}}'
	@$(KUBECTL) exec deployment/$(GREEN_DEPLOY) -- curl -fsS http://127.0.0.1:8090/health >/dev/null \
		&& printf '%b\n' "$(BG)$(OK) Service → green$(R)"
	@$(KUBECTL) scale deployment/$(BLUE_DEPLOY) --replicas=0
	@printf '%b\n' "$(D) blue parked (replicas=0). Roll back: make k8s-rollback$(R)"

k8s-rollback: ## Flip Service back to blue, park green
	@printf '%b\n' "$(Y)$(WR) rolling Service back → $(BLUE_DEPLOY)$(R)"
	@$(KUBECTL) scale deployment/$(BLUE_DEPLOY) --replicas=1
	@$(KUBECTL) rollout status deployment/$(BLUE_DEPLOY) --timeout=120s
	@$(KUBECTL) patch svc $(BLUE_DEPLOY) -p '{"spec":{"selector":{"app":"$(BLUE_DEPLOY)"}}}'
	@$(KUBECTL) scale deployment/$(GREEN_DEPLOY) --replicas=0 || true
	@printf '%b\n' "$(BG)$(OK) Service → blue, green parked$(R)"

k8s-status: ## Blue/green status: deployments, Service selector, pods
	@printf '\n$(B)deployments$(R)\n'
	@$(KUBECTL) get deployments -l 'app in ($(BLUE_DEPLOY),$(GREEN_DEPLOY))' -o wide 2>&1 | sed 's/^/  /' \
		|| $(KUBECTL) get deployments | grep -E 'gateway|NAME' | sed 's/^/  /'
	@printf '\n$(B)service selector$(R)\n'
	@$(KUBECTL) get svc $(BLUE_DEPLOY) -o jsonpath='  selector: {.spec.selector}{"\n"}'
	@printf '\n$(B)pods$(R)\n'
	@$(KUBECTL) get pods -o wide | grep -E 'gateway|NAME' | sed 's/^/  /' || true

k8s-clean-green: ## Delete green Deployment (post-verify cleanup)
	@printf '%b\n' "$(Y)$(WR) deleting deployment/$(GREEN_DEPLOY)$(R)"
	@$(KUBECTL) delete deployment $(GREEN_DEPLOY) --ignore-not-found=true

k8s-abort: k8s-clean-green ## Abort pre-promote green (alias for k8s-clean-green)
