# ============================================================================
# IRC Fiber Infra — Deploys (repo root)
# ============================================================================
# There was never a Makefile here (nothing was deleted — git history has no
# root Makefile; `site/` is a submodule whose wrapper is site/Makefile).
# This file is the single entry point for deploys.
#
# Pipeline (gateway and engine alike):
#   laptop  --git push-->  builder (ubuntu-docker: buildx, warm dub/npm cache)
#   builder --buildx --push-->  GHCR  (tag sha-<short>; digest captured)
#   laptop  --ansible-->  prod pulls BY DIGEST, swaps, asserts the running
#                         image id == requested, laptop gates on /api/version
#   builder --imagetools-->  GHCR :prod  (promoted only after the swap held)
# The laptop never carries image bytes. A frontend-only change never
# recompiles D; a D-only change never runs vite (see site/Containerfile).
#
# Gateway swaps are blue/green (zero downtime). The engine (IRC daemon) holds
# TCP/TLS + JOIN state and deploys by hard restart BY DESIGN — see AGENTS.md
# "Engine Lifecycle". Do not blue/green the engine.
#
# Two fleets:
#   OVH prod (docker over ansible) — targets without prefix
#     make ship           # gateway: tag-prev → build+push → swap by digest → gate → promote :prod
#     make ship-engine    # engine:  build+push → restart by digest → gate → promote :prod
#     make warm           # pre-build HEAD on the builder in the background (no deploy)
#     make swap           # redeploy $(GW_REPO):prod (no build)
#     make rollback       # swap back to :blue-prev (health-checked)
#     make status|health|logs|engine-status
#   k3s dev (kubectl) — k8s-* targets
#     make k8s-deploy     # build+push :green → green Deployment → wait
#     make k8s-promote    # flip Service to green, park blue (replicas=0)
#     make k8s-rollback   # flip Service back to blue
#     make deploy-ircd-k8s # InspIRCd leaf pod on k3s, linked to the OVH hub
#     make k8s-status|k8s-clean-green
#
# Overrides: TARGET=host  VAULT_PASS_FILE=path  BUILDER=user@host  GREEN_TAG=tag
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

# Builder + registry. The builder keeps a bare-ish clone per repo that the
# laptop force-pushes HEAD into (refs/heads/ship); its BuildKit cache holds
# the warm dub/npm mounts, so a one-file change is an incremental compile.
BUILDER        ?= ubuntu@ubuntu-docker
BUILDER_SITE   ?= /home/ubuntu/ircfiber-build/site
BUILDER_ENGINE ?= /home/ubuntu/ircfiber-build/engine
GW_REPO        ?= ghcr.io/kevinpostal/irc-fiber-gateway
EN_REPO        ?= ghcr.io/kevinpostal/ircfiber-engine
SITE_URL       ?= https://ircfiber.com

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
# One multiplexed ssh session per host for the whole deploy: each hop is a
# DERP-relayed tailnet link, so every un-muxed connection pays a full setup.
SSH_MUX = -o ControlMaster=auto -o ControlPath=/tmp/ircfiber-%r@%h:%p -o ControlPersist=180s
SSH    = ssh $(SSH_MUX) -F /dev/null -o IdentitiesOnly=yes -i $(SSH_KEY) -o StrictHostKeyChecking=no deploy@$(_SSH_HOST)
BSSH   = ssh $(SSH_MUX) -o StrictHostKeyChecking=no -o ConnectTimeout=20 $(BUILDER)
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
	@printf '\n$(B)IRC Fiber Infra — Deploys$(R) $(D)(build on $(BUILDER), deliver via GHCR by digest; engine deploys by hard restart, see AGENTS.md)$(R)\n'
	@printf '$(D)============================================================$(R)\n'
	@printf '\n$(B)OVH prod (ansible/docker)$(R)\n'
	@awk 'BEGIN{FS=":.*##[ \t]*"} /^[a-zA-Z0-9_.-]+:.*##/{t=$$1; c=$$2; if (t !~ /^k8s/) {printf "  $(G)make %-*s$(R) %s\n", 18, t, c}}' $(MAKEFILE_LIST)
	@printf '\n$(B)k3s dev (kubectl)$(R)\n'
	@awk 'BEGIN{FS=":.*##[ \t]*"} /^k8s-[a-zA-Z0-9_.-]+:.*##/{printf "  $(C)make %-*s$(R) %s\n", 18, $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\n$(D)Defaults: TARGET=$(TARGET)  BUILDER=$(BUILDER)  GREEN_TAG=$(GREEN_TAG)  KUBE_CONTEXT=$(KUBE_CONTEXT)/$(KUBE_NS)$(R)\n\n'

# ============================================================================
# OVH prod — build on the builder, deliver via GHCR, swap by digest
# ============================================================================
.PHONY: ship ship-engine warm deploy-ircd deploy-ircd-k8s deploy-k3s-node-tune rehash-ircd tag-prev swap rollback status health logs engine-status

# One script for gateway and engine; the per-target knobs come in as env.
# Every step is a plain command under `set -euo pipefail` — nothing ends in
# `| tail`. The old path once reported success while prod ran the old binary
# because a `| tail -N` made the recipe's exit status tail's (always 0).
#
#   SRC     submodule dir (site | engine)          BDIR   its clone on the builder
#   CF      Containerfile                          STAGE  buildx --target
#   REPO    GHCR repository                         META   buildx --metadata-file on the builder
#   PLAYBOOK / REFVAR                              which playbook, and the -e var carrying the digest ref
#   GATE    gateway | engine                       how the laptop proves the served commit
#   MODE    ship | warm                            warm = steps 1–5 only, build detached, no deploy/promote
define SHIP_SH
set -euo pipefail
cd "$$ROOT"

# 1. Refuse a dirty tree: the image is built from the commit, never the
#    worktree. ALLOW_DIRTY=1 ships anyway after printing what is being left
#    behind — needed when an unrelated file is mid-edit in another session
#    and the change to deploy is already committed.
dirty=$$( { git -C "$$SRC" diff --name-only HEAD; git -C "$$SRC" ls-files --others --exclude-standard; } )
if [ -n "$$dirty" ]; then
  printf '%b\n' "$(Y)$(WR) $$SRC/ working tree is dirty — these are NOT in the image:$(R)"
  printf '  %s\n' $$dirty
  if [ -z "$(ALLOW_DIRTY)" ]; then
    printf '%b\n' "$(Y)  commit them, or re-run with ALLOW_DIRTY=1 to ship HEAD as-is$(R)"
    exit 1
  fi
fi

# 2. Identity of the commit being shipped.
SHA=$$(git -C "$$SRC" rev-parse HEAD)
SHORT=$$(git -C "$$SRC" rev-parse --short=12 HEAD)
DESCRIBE=$$(git -C "$$SRC" describe --always --long)
BRANCH=$$(git -C "$$SRC" rev-parse --abbrev-ref HEAD)
MSG=$$(git -C "$$SRC" log -1 --pretty=%s | tr -d "'\"")
BUILT=$$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%b\n' "$(C)$(AR) $$MODE $$SRC @ $$SHORT ($$DESCRIBE) — $$MSG$(R)"

# 3. Feed the builder: git moves only missing objects (kilobytes after the
#    first push), instead of re-walking a 14 MB tree with rsync.
GIT_SSH_COMMAND="ssh $(SSH_MUX) -o StrictHostKeyChecking=no" \
  git -C "$$SRC" push --force --quiet "ssh://$(BUILDER)$$BDIR" HEAD:refs/heads/ship

# 4. Check it out there and assert the builder holds exactly this commit.
got=$$($(BSSH) "cd $$BDIR && git checkout -q --detach --force ship && git clean -xdfq && git rev-parse HEAD")
if [ "$$got" != "$$SHA" ]; then echo "✗ builder has $$got, expected $$SHA" >&2; exit 1; fi

# 5. Build and push the sha- tag. :prod is promoted in step 9, after the swap
#    has held, so a failed deploy never moves :prod.
build="cd $$BDIR && docker buildx build --target $$STAGE -f $$CF \
  --build-arg GIT_HASH=$$SHA --build-arg GIT_SHORT=$$SHORT \
  --build-arg GIT_DESCRIBE=$$DESCRIBE --build-arg GIT_BRANCH=$$BRANCH \
  --build-arg BUILD_TIME=$$BUILT --build-arg GIT_MESSAGE=$$(printf '%q' "$$MSG") \
  --tag $$REPO:sha-$$SHORT --push --metadata-file $$META ."
if [ "$$MODE" = warm ]; then
  $(BSSH) -n "nohup bash -c $$(printf '%q' "$$build") >$$META.log 2>&1 &"
  printf '%b\n' "$(BG)$(OK) warming $$REPO:sha-$$SHORT on $(BUILDER) — log: $$META.log$(R)"
  exit 0
fi
$(BSSH) "$$build"

# 6. The digest is what prod pulls — never a mutable tag.
DIGEST=$$($(BSSH) "jq -r '.\"containerimage.digest\"' $$META")
case "$$DIGEST" in sha256:[0-9a-f]*) [ $${#DIGEST} -eq 71 ] ;; *) false ;; esac \
  || { echo "✗ bad digest from buildx metadata: '$$DIGEST'" >&2; exit 1; }
printf '%b\n' "$(C)$(AR) pushed $$REPO@$$DIGEST$(R)"

# 7. Pull by digest, swap, and assert the running container is that image id.
( cd site/deploy && ansible-playbook -l $(TARGET) --vault-password-file $(VAULT_PASS_FILE) \
    playbooks/$$PLAYBOOK -e $$REFVAR=$$REPO@$$DIGEST )

# 8. Gate from outside: the in-play assertion proves the container, this
#    proves the served process.
case "$$GATE" in
  gateway)
    # /api/version intermittently truncates at 121 bytes (vibe.d writeJsonBody);
    # an unparseable body is retried, a parseable *other* commit fails at once.
    for i in $$(seq 1 15); do
      served=$$(curl -fsS -H 'Cache-Control: no-cache' "$(SITE_URL)/api/version" | jq -r .commit 2>/dev/null || true)
      [ "$$served" = "$$SHA" ] && break
      if [ -n "$$served" ]; then echo "✗ $(SITE_URL) serves $$served, expected $$SHA" >&2; exit 1; fi
      [ "$$i" -lt 15 ] || { echo "✗ $(SITE_URL)/api/version unreadable after 15 tries" >&2; exit 1; }
      sleep 1
    done
    ;;
  engine)
    # The engine re-registers in Redis on boot; give it up to 60 s.
    for i in $$(seq 1 60); do
      if curl -fsS -H 'Cache-Control: no-cache' "$(SITE_URL)/api/version" \
           | jq -r '.engines[].gitShort' 2>/dev/null | grep -qx "$$SHORT"; then break; fi
      [ "$$i" -lt 60 ] || { echo "✗ no engine reports $$SHORT after 60s" >&2; exit 1; }
      sleep 1
    done
    ;;
esac

# 9. Promote: a manifest-only registry write, no bytes re-uploaded.
$(BSSH) "docker buildx imagetools create -t $$REPO:prod $$REPO@$$DIGEST"
printf '%b\n' "$(BG)$(OK) $$SRC $$SHORT live on $(TARGET); $$REPO:prod → $$DIGEST$(R)"
endef
export SHIP_SH

_GW_ENV = ROOT=$(CURDIR) SRC=site   BDIR=$(BUILDER_SITE)   CF=Containerfile        STAGE=runtime-gateway REPO=$(GW_REPO) META=/tmp/gw-meta.json PLAYBOOK=gateway-deploy.yml REFVAR=gateway_image_ref GATE=gateway
_EN_ENV = ROOT=$(CURDIR) SRC=engine BDIR=$(BUILDER_ENGINE) CF=Containerfile.engine STAGE=runtime-engine  REPO=$(EN_REPO) META=/tmp/en-meta.json PLAYBOOK=engine-deploy.yml  REFVAR=engine_image_ref  GATE=engine

ship: tag-prev ## Gateway: tag-prev → build on builder → push GHCR → blue/green swap by digest → gate → promote :prod
	@printf '\n$(BG)$(OK) Ship gateway → $(TARGET) (engine untouched)$(R)\n'
	@$(_GW_ENV) MODE=ship bash -c "$$SHIP_SH"

ship-engine: ## Engine: build on builder → push GHCR → restart by digest (brief IRC reconnect) → gate → promote :prod
	@printf '\n$(Y)$(WR) Ship engine → $(TARGET) (hard restart, brief IRC disconnect)$(R)\n'
	@$(_EN_ENV) MODE=ship bash -c "$$SHIP_SH"

warm: ## Pre-build the gateway image for HEAD on the builder in the background (never promotes :prod)
	@$(_GW_ENV) MODE=warm bash -c "$$SHIP_SH"

tag-prev: ## Tag running gateway image as :blue-prev (rollback anchor)
	@printf '%b\n' "$(C)$(AR) tagging live gateway image → irc-fiber-gateway:blue-prev on $(TARGET)$(R)"
	@$(SSH) 'img=$$(sudo docker inspect -f "{{.Image}}" ircfiber-gateway 2>/dev/null) && sudo docker tag "$$img" irc-fiber-gateway:blue-prev && echo "blue-prev=$$img"'

swap: ## Redeploy $(GW_REPO):prod (the last promoted image) — no build
	@printf '\n$(BG)$(OK) Blue/green swap → $(TARGET) from $(GW_REPO):prod (no build)$(R)\n'
	@$(PLAY) playbooks/gateway-deploy.yml

rollback: ## Roll back gateway to :blue-prev image (health-checked swap, engine untouched)
	@printf '\n$(Y)$(WR) Rollback gateway → irc-fiber-gateway:blue-prev on $(TARGET)$(R)\n'
	@$(SSH) 'sudo docker inspect irc-fiber-gateway:blue-prev >/dev/null 2>&1 || { echo "✗ no :blue-prev image on host — deploy-blue tags it first"; exit 1; }'
	@# An anchor identical to what is running is not an anchor. tag-prev runs
	@# BEFORE the build, so if a previous deploy failed between tag-prev and the
	@# swap, :blue-prev == the live image and "rolling back" would silently
	@# redeploy the broken version while reporting success. Refuse that.
	@$(SSH) 'prev=$$(sudo docker inspect -f "{{.Id}}" irc-fiber-gateway:blue-prev); \
	  live=$$(sudo docker inspect -f "{{.Image}}" ircfiber-gateway); \
	  if [ "$$prev" = "$$live" ]; then \
	    echo "✗ :blue-prev is the image already running ($${live%%*}) — there is nothing to roll back to"; exit 1; \
	  fi; \
	  echo "rolling back: live=$$live → prev=$$prev"'
	@$(PLAY) playbooks/gateway-deploy.yml -e gateway_image_ref=irc-fiber-gateway:blue-prev
	@printf '%b\n' "$(BG)$(OK) Rolled back to :blue-prev — verify: make health$(R)"

status: ## Remote container status (playbook)
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

# The InspIRCd spanningtree leaf on k3s. Renders the same templates as the OVH
# hub in leaf mode onto the node (hostPath: no k8s Secret is creatable on that
# cluster), applies the manifests and rehashes the pod. Run this BEFORE
# `make deploy-ircd`, so the hub has something to autoconnect to.
deploy-ircd-k8s: ## Render + apply the InspIRCd k3s leaf (ns ircfiber-prod) and rehash it
	@printf '\n$(BG)$(OK) IRCd k3s leaf → ubuntu-docker / ircfiber-prod$(R)\n'
	cd site/deploy && ansible-playbook --vault-password-file $(VAULT_PASS_FILE) playbooks/ircd-k8s-leaf.yml

# kubelet eviction thresholds on the k3s node. Needed because the node's disk
# is the odysseus host's 1.7T volume: a percentage threshold there is larger
# than everything the cluster stores, and when it trips kubelet rejects every
# non-critical pod. Restarts k3s (no systemd on that node), so run it
# deliberately, not as part of a deploy.
deploy-k3s-node-tune: ## Apply kubelet eviction tuning on the k3s node (restarts k3s)
	@printf '\n$(BG)$(OK) kubelet eviction tuning → ubuntu-docker$(R)\n'
	cd site/deploy && ansible-playbook --vault-password-file $(VAULT_PASS_FILE) playbooks/k3s-node-tune.yml

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
