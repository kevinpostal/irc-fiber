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
# Gateway swaps are blue/green (zero downtime). The engine (IRC daemon) is a
# HOT SWAP: the connection holder (ircfiber-holder-<id>) owns every IRC
# TCP/TLS socket, the old engine detaches on SIGTERM and the new one
# reattaches — no IRC reconnect. Only `make ship-holder` (rare) and
# `make engine-decommission` drop IRC sessions. Do not blue/green the engine.
#
# Two fleets:
#   OVH prod (docker over ansible) — targets without prefix
#     make ship           # gateway: tag-prev → build+push → swap by digest → gate → promote :prod
#     make ship-engine    # engine:  build+push → hot swap by digest (IRC sockets kept) → gate → promote :prod
#     make ship-holder    # holder:  build+push → recreate by digest (FULL IRC RECONNECT) → gate → promote :prod
#     make warm           # pre-build HEAD on the builder in the background (no deploy)
#     make swap           # redeploy $(GW_REPO):prod (no build)
#     make rollback       # swap back to :blue-prev (health-checked)
#     make status|health|logs|engine-status|engine-decommission
#     make builder-df|builder-gc|builder-gc-hard   # builder disk hygiene
#   Builder out of space (it is a container on a volume shared with tenants
#   we do not control): every ship checks BUILDER_MIN_FREE_GB first and caps
#   the BuildKit cache at BUILDER_CACHE_KEEP afterwards. When even that is
#   not enough, build in GitHub Actions and never touch the builder:
#     BUILD_ON=ci make ship        # same image, same gate, cold compile
#   k3s dev (kubectl) — k8s-* targets
#     make k8s-deploy     # build+push :green → green Deployment → wait
#     make k8s-promote    # flip Service to green, park blue (replicas=0)
#     make k8s-rollback   # flip Service back to blue
#     make deploy-ircd-k8s # InspIRCd leaf pod on k3s, linked to the OVH hub
#     make k8s-status|k8s-clean-green
#
# Overrides: TARGET=host  VAULT_PASS_FILE=path  BUILDER=user@host  GREEN_TAG=tag
#            BUILD_ON=builder|ci  BUILDER_MIN_FREE_GB=N  BUILDER_CACHE_KEEP=NGB
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

# The builder is a container on a 1.7 T volume shared with tenants we do not
# control; it has hit 0 bytes free mid-deploy. Our footprint is therefore
# capped rather than left to grow: every ship trims the BuildKit cache back
# to BUILDER_CACHE_KEEP, and refuses to start unless BUILDER_MIN_FREE_GB is
# available. BUILD_ON=ci bypasses the builder entirely (GitHub Actions).
BUILD_ON             ?= builder
BUILDER_MIN_FREE_GB  ?= 8
BUILDER_CACHE_KEEP   ?= 6GB
GW_REPO        ?= ghcr.io/kevinpostal/irc-fiber-gateway
EN_REPO        ?= ghcr.io/kevinpostal/ircfiber-engine
HO_REPO        ?= ghcr.io/kevinpostal/ircfiber-holder
IRCD_REPO      ?= ghcr.io/kevinpostal/irc-fiber-ircd
ANOPE_REPO     ?= ghcr.io/kevinpostal/irc-fiber-anope
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
	@printf '\n$(B)IRC Fiber Infra — Deploys$(R) $(D)(build on $(BUILDER), deliver via GHCR by digest; engine deploys are hot swaps, see AGENTS.md)$(R)\n'
	@printf '$(D)============================================================$(R)\n'
	@printf '\n$(B)OVH prod (ansible/docker)$(R)\n'
	@awk 'BEGIN{FS=":.*##[ \t]*"} /^[a-zA-Z0-9_.-]+:.*##/{t=$$1; c=$$2; if (t !~ /^k8s/) {printf "  $(G)make %-*s$(R) %s\n", 18, t, c}}' $(MAKEFILE_LIST)
	@printf '\n$(B)k3s dev (kubectl)$(R)\n'
	@awk 'BEGIN{FS=":.*##[ \t]*"} /^k8s-[a-zA-Z0-9_.-]+:.*##/{printf "  $(C)make %-*s$(R) %s\n", 18, $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\n$(D)Defaults: TARGET=$(TARGET)  BUILDER=$(BUILDER)  GREEN_TAG=$(GREEN_TAG)  KUBE_CONTEXT=$(KUBE_CONTEXT)/$(KUBE_NS)$(R)\n\n'

# ============================================================================
# OVH prod — build on the builder, deliver via GHCR, swap by digest
# ============================================================================
.PHONY: builder-df builder-gc builder-gc-hard ship ship-engine ship-holder ship-ircd warm deploy-ircd deploy-ircd-k8s deploy-ircd-network ircd-parity ircd-leaf-status deploy-k3s-node-tune rehash-ircd tag-prev swap rollback status health logs engine-status engine-decommission

# One script for gateway and engine; the per-target knobs come in as env.
# Every step is a plain command under `set -euo pipefail` — nothing ends in
# `| tail`. The old path once reported success while prod ran the old binary
# because a `| tail -N` made the recipe's exit status tail's (always 0).
#
#   SRC     submodule dir (site | engine)          BDIR   its clone on the builder
#   CF      Containerfile                          STAGE  buildx --target
#   REPO    GHCR repository                         META   buildx --metadata-file on the builder
#   PLAYBOOK / REFVAR                              which playbook, and the -e var carrying the digest ref
#   GATE    gateway | engine | holder | ircd   how the laptop proves the served process
#   MODE    ship | warm                            warm = build only, no deploy/promote
#   BUILD_ON builder | ci                          where the image bytes are produced
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

# 3. Where the bytes are built.
#      BUILD_ON=builder  ubuntu-docker, warm BuildKit cache mounts, fast.
#      BUILD_ON=ci       GitHub Actions build-image.yml — touches no builder
#                        disk at all, cold D compile, use when the builder
#                        host (a container on a 1.7T volume shared with
#                        tenants we do not control) is out of space.
if [ "$$BUILD_ON" = ci ]; then
  GH_REPO=$$(git -C "$$SRC" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$$##')
  # CI builds what GitHub has, not what is on this laptop.
  remote=$$(git -C "$$SRC" ls-remote origin "refs/heads/$$BRANCH" | cut -f1)
  if [ "$$remote" != "$$SHA" ]; then
    echo "✗ $$GH_REPO $$BRANCH is $$remote, expected $$SHA — push the commit first" >&2; exit 1
  fi
  before=$$(gh -R "$$GH_REPO" run list --workflow=build-image.yml --limit 1 --json databaseId --jq '.[0].databaseId // 0')
  gh -R "$$GH_REPO" workflow run build-image.yml --ref "$$BRANCH" \
    -f containerfile="$$CF" -f target="$$STAGE" -f image="$${REPO##*/}"
  run=$$before
  for i in $$(seq 1 30); do
    run=$$(gh -R "$$GH_REPO" run list --workflow=build-image.yml --limit 1 --json databaseId --jq '.[0].databaseId // 0')
    [ "$$run" != "$$before" ] && break
    sleep 2
  done
  if [ "$$run" = "$$before" ]; then echo "✗ dispatched run never appeared in $$GH_REPO" >&2; exit 1; fi
  printf '%b\n' "$(C)$(AR) building in CI: https://github.com/$$GH_REPO/actions/runs/$$run$(R)"
  gh -R "$$GH_REPO" run watch "$$run" --exit-status
  [ "$$MODE" = warm ] && exit 0
  # 4. The digest is what prod pulls — read it back from the registry, so a
  #    workflow that lied about pushing fails here rather than at the swap.
  DIGEST=$$(curl -sS -D- -o /dev/null \
    -H "Authorization: Bearer $$(gh auth token | base64)" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
    "https://ghcr.io/v2/$${REPO#ghcr.io/}/manifests/sha-$$SHORT" \
    | awk 'tolower($$1) == "docker-content-digest:" { print $$2 }' | tr -d '\r')
else
  # 3a. Disk guard. The builder filling up used to surface as an unrelated
  #     `git push` failure ("unable to create temporary object directory").
  #     Check first, reclaim what is ours, and say what to do if that is not
  #     enough — never start a 5 minute build that cannot finish.
  free=$$($(BSSH) "df -BG --output=avail / | tail -1 | tr -dc 0-9")
  if [ "$$free" -lt $(BUILDER_MIN_FREE_GB) ]; then
    printf '%b\n' "$(Y)$(WR) builder has $${free}G free — reclaiming (cache cap $(BUILDER_CACHE_KEEP))$(R)"
    $(BSSH) "docker builder prune -f --keep-storage=$(BUILDER_CACHE_KEEP); docker image prune -f; docker volume prune -f" >/dev/null || true
    free=$$($(BSSH) "df -BG --output=avail / | tail -1 | tr -dc 0-9")
  fi
  if [ "$$free" -lt $(BUILDER_MIN_FREE_GB) ]; then
    echo "✗ builder $(BUILDER) has only $${free}G free, needs $(BUILDER_MIN_FREE_GB)G" >&2
    echo "  build in CI instead:  BUILD_ON=ci make <target>" >&2
    echo "  or drop the whole BuildKit cache (cold next build):  make builder-gc-hard" >&2
    exit 1
  fi

  # 3b. Feed the builder: git moves only missing objects (kilobytes after the
  #     first push), instead of re-walking a 14 MB tree with rsync.
  GIT_SSH_COMMAND="ssh $(SSH_MUX) -o StrictHostKeyChecking=no" \
    git -C "$$SRC" push --force --quiet "ssh://$(BUILDER)$$BDIR" HEAD:refs/heads/ship

  # 3c. Check it out there and assert the builder holds exactly this commit.
  got=$$($(BSSH) "cd $$BDIR && git checkout -q --detach --force ship && git clean -xdfq && git rev-parse HEAD")
  if [ "$$got" != "$$SHA" ]; then echo "✗ builder has $$got, expected $$SHA" >&2; exit 1; fi

  # 3d. Build and push the sha- tag. :prod is promoted in step 9, after the
  #     swap has held, so a failed deploy never moves :prod.
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

  # 3e. Hold the cache to a fixed size. Unbounded, it grew to 9 GB and took
  #     the shared volume to 0 bytes; capped, a ship's footprint is constant.
  $(BSSH) "docker builder prune -f --keep-storage=$(BUILDER_CACHE_KEEP)" >/dev/null || true

  # 4. The digest is what prod pulls — never a mutable tag.
  DIGEST=$$($(BSSH) "jq -r '.\"containerimage.digest\"' $$META")
fi
case "$$DIGEST" in sha256:[0-9a-f]*) [ $${#DIGEST} -eq 71 ] ;; *) false ;; esac \
  || { echo "✗ bad digest for $$REPO:sha-$$SHORT: '$$DIGEST'" >&2; exit 1; }
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
  holder)
    # The holder reports its own build in STATUS; the in-play assertion
    # proved the container, this proves the process answering the IPC.
    for i in $$(seq 1 60); do
      served=$$($(SSH) 'sudo docker exec ircfiber-holder-ovh /app/irc-fiber-holder --status' 2>/dev/null | jq -r .holder 2>/dev/null || true)
      [ "$$served" = "$$SHORT" ] && break
      [ "$$i" -lt 60 ] || { echo "✗ ircfiber-holder-ovh reports '$$served', expected $$SHORT after 60s" >&2; exit 1; }
      sleep 1
    done
    ;;
  ircd)
    # The in-play assertion proved the container runs the digest; this
    # proves the module shipped in it and loaded (or, before the tag is in
    # modules.conf, at least did not error).
    $(SSH) 'sudo docker exec ircfiber-ircd test -f /inspircd/modules/m_motdpool.so' \
      || { echo "✗ ircfiber-ircd has no /inspircd/modules/m_motdpool.so" >&2; exit 1; }
    if $(SSH) 'sudo docker logs --since 3m ircfiber-ircd 2>&1' | grep -Ei 'motdpool.*(unable|error)'; then
      echo "✗ motdpool errors in ircfiber-ircd log" >&2; exit 1
    fi
    ;;
  services)
    # The in-play assertion proved the container runs the digest. This
    # proves the modules the gateway and the bridge depend on shipped in it
    # (CMake SKIPS a module whose dependencies it cannot detect rather than
    # failing the build), that the database loaded, that the link to the
    # ircd came up, and that BridgeServ actually reached Discord — a bad
    # token or blocked egress leaves a healthy container relaying nothing.
    for m in bridgeserv rpc_registered rpc_user rpc_data jsonrpc db_json; do
      $(SSH) "sudo docker exec ircfiber-services test -f /anope/modules/$$m.so" \
        || { echo "✗ ircfiber-services has no /anope/modules/$$m.so" >&2; exit 1; }
    done
    for i in $$(seq 1 60); do
      log=$$($(SSH) 'sudo docker logs --since 5m ircfiber-services 2>&1')
      echo "$$log" | grep -q 'Databases loaded' \
        && echo "$$log" | grep -q 'Successfully connected to uplink' \
        && echo "$$log" | grep -q 'connected to Discord' && break
      [ "$$i" -lt 60 ] || { echo "✗ ircfiber-services never logged 'Databases loaded' + 'Successfully connected to uplink' + 'connected to Discord'" >&2; exit 1; }
      sleep 2
    done
    ;;
esac

# 9. Promote: a manifest-only registry write, no bytes re-uploaded. In CI
#    mode the builder may be full or unreachable, so promote from here —
#    `gh auth token` is the same GHCR credential the workflow pushed with.
if [ "$$BUILD_ON" = ci ]; then
  gh auth token | docker login ghcr.io -u "$$(gh api user --jq .login)" --password-stdin >/dev/null
  docker buildx imagetools create -t $$REPO:prod $$REPO@$$DIGEST
else
  $(BSSH) "docker buildx imagetools create -t $$REPO:prod $$REPO@$$DIGEST"
fi
printf '%b\n' "$(BG)$(OK) $$SRC $$SHORT live on $(TARGET); $$REPO:prod → $$DIGEST$(R)"
endef
export SHIP_SH

_GW_ENV = ROOT=$(CURDIR) BUILD_ON=$(BUILD_ON) SRC=site   BDIR=$(BUILDER_SITE)   CF=Containerfile        STAGE=runtime-gateway REPO=$(GW_REPO) META=/tmp/gw-meta.json PLAYBOOK=gateway-deploy.yml REFVAR=gateway_image_ref GATE=gateway
_EN_ENV = ROOT=$(CURDIR) BUILD_ON=$(BUILD_ON) SRC=engine BDIR=$(BUILDER_ENGINE) CF=Containerfile.engine STAGE=runtime-engine  REPO=$(EN_REPO) META=/tmp/en-meta.json PLAYBOOK=engine-deploy.yml  REFVAR=engine_image_ref  GATE=engine
_HO_ENV = ROOT=$(CURDIR) BUILD_ON=$(BUILD_ON) SRC=engine BDIR=$(BUILDER_ENGINE) CF=Containerfile.engine STAGE=runtime-holder  REPO=$(HO_REPO) META=/tmp/ho-meta.json PLAYBOOK=holder-deploy.yml  REFVAR=holder_image_ref  GATE=holder
_IRCD_ENV = ROOT=$(CURDIR) BUILD_ON=$(BUILD_ON) SRC=site BDIR=$(BUILDER_SITE) CF=deploy/roles/ircd/files/Containerfile.ircd STAGE=runtime-ircd REPO=$(IRCD_REPO) META=/tmp/ircd-meta.json PLAYBOOK=ircd-deploy.yml REFVAR=ircd_image_ref GATE=ircd
_ANOPE_ENV = ROOT=$(CURDIR) BUILD_ON=$(BUILD_ON) SRC=site BDIR=$(BUILDER_SITE) CF=deploy/roles/ircd/files/Containerfile.anope STAGE=runtime-anope REPO=$(ANOPE_REPO) META=/tmp/anope-meta.json PLAYBOOK=services-deploy.yml REFVAR=ircd_services_image_ref GATE=services

builder-df: ## Builder disk: free space + what our docker is holding
	@$(BSSH) 'df -h / | tail -1; docker system df'

builder-gc: ## Builder: trim BuildKit cache to BUILDER_CACHE_KEEP, drop dangling images/volumes
	@$(BSSH) 'docker builder prune -f --keep-storage=$(BUILDER_CACHE_KEEP); docker image prune -f; docker volume prune -f; df -h / | tail -1'

builder-gc-hard: ## Builder: drop the ENTIRE BuildKit cache (next build is cold, ~10 min)
	@printf '%b\n' "$(Y)$(WR) dropping all BuildKit cache on $(BUILDER) — next build recompiles from scratch$(R)"
	@$(BSSH) 'docker buildx prune -af; docker image prune -f; docker volume prune -f; df -h / | tail -1'

ship: tag-prev ## Gateway: tag-prev → build on builder → push GHCR → blue/green swap by digest → gate → promote :prod
	@printf '\n$(BG)$(OK) Ship gateway → $(TARGET) (engine untouched)$(R)\n'
	@$(_GW_ENV) MODE=ship bash -c "$$SHIP_SH"

ship-engine: ## Engine: build on builder → push GHCR → hot swap by digest (IRC sockets kept) → gate → promote :prod
	@printf '\n$(BG)$(OK) Ship engine → $(TARGET) (hot swap, IRC sockets kept)$(R)\n'
	@$(_EN_ENV) MODE=ship bash -c "$$SHIP_SH"

# The holder owns every IRC socket; recreating it is the one engine-side
# deploy that still drops IRC sessions. Ship it first (once), then engines
# hot swap against it forever. Rollout order for a new registry grace:
# make ship (gateway) → make ship-holder → make ship-engine.
ship-holder: ## Holder: build on builder → push GHCR → RECREATE holder by digest (full IRC reconnect) → gate → promote :prod
	@printf '\n$(Y)$(WR) Ship holder → $(TARGET) (container recreate: FULL IRC RECONNECT on every network)$(R)\n'
	@$(_HO_ENV) MODE=ship bash -c "$$SHIP_SH"

# The ircd image is upstream InspIRCd plus our motdpool module
# (site/deploy/roles/ircd/files/Containerfile.ircd). Config changes never
# need this — `make deploy-ircd` rehashes in place. A new IMAGE recreates
# the container: every IRC client drops and Anope relinks. Run it in a quiet
# window, then roll the k3s leaf to the same digest (make deploy-ircd-k8s
# after setting the image in k8s/ircfiber-prod/deployment-ircd-leaf.yaml).
ship-ircd: ## IRCd image: build on builder → push GHCR → RECREATE ircd by digest (all IRC clients drop) → gate → promote :prod
	@printf '\n$(Y)$(WR) Ship ircd image → $(TARGET) (container recreate: every IRC client disconnects, Anope relinks)$(R)\n'
	@$(_IRCD_ENV) MODE=ship bash -c "$$SHIP_SH"

# The services image is our Anope 2.1 + bridgeserv build
# (site/deploy/roles/ircd/files/Containerfile.anope): NickServ, ChanServ,
# BotServ, OperServ AND the Discord bridge in one process. Config changes
# never need this — `make deploy-ircd` re-renders and restarts services in
# place. A new IMAGE recreates the container: every user's services session
# (identification, +r) drops until they re-identify or SASL reconnects, and
# the Discord relay is down for the restart. IRC clients and the ircd are
# untouched.
ship-services: ## Services (Anope 2.1 + bridgeserv) image: build on builder → push GHCR → recreate ircfiber-services by digest → gate → promote :prod
	@printf '\n$(Y)$(WR) Ship services image → $(TARGET) (container recreate: services sessions and the Discord relay drop for the restart; IRC clients unaffected)$(R)\n'
	@$(_ANOPE_ENV) MODE=ship bash -c "$$SHIP_SH"

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

engine-status: ## Prove engine + holder state (engine PID/uptime; holder uptime + attached sessions must not change across engine deploys)
	@$(SSH) 'sudo docker exec ircfiber-engine-ovh pidof irc-fiber-engine | xargs -I {} echo "engine PID {}"; sudo docker ps --format "{{.Names}} {{.Status}}" | grep -E "engine|holder"; sudo docker exec ircfiber-holder-ovh /app/irc-fiber-holder --status'

# Decommission = SIGINT: the engine QUITs every network, unregisters and
# publishes irc:shutdown so the other engines/gateway reassign at once;
# then both containers go. SIGTERM (docker stop) would only detach.
engine-decommission: ## Retire this host's engine: SIGINT (QUIT all, unregister, irc:shutdown) then remove engine + holder containers
	@printf '\n$(Y)$(WR) Decommission engine + holder on $(TARGET): every IRC network QUITs and is reassigned$(R)\n'
	@$(SSH) 'sudo docker kill -s INT ircfiber-engine-ovh && sudo docker wait ircfiber-engine-ovh && sudo docker rm ircfiber-engine-ovh && sudo docker rm -f ircfiber-holder-ovh'
	@printf '%b\n' "$(BG)$(OK) ircfiber-engine-ovh and ircfiber-holder-ovh removed — verify: redis SMEMBERS irc:servers$(R)"

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

# Leaf ON/OFF lives in the gateway's admin page (Operations → K8s leaf): it
# runs the preflight checks, scales the k3s Deployment 0↔1 and issues
# CONNECT/SQUIT as the `dashboard` oper. The Deployment's replica count is the
# single source of truth for "on"; the hub only DECLARES the <link> (no
# <autoconnect> — its 16s retry turned an evicted pod into a REMOTELINK
# snotice storm on every linked network). This target is the CLI mirror.
ircd-leaf-status: ## Read-only mirror of the admin K8s-leaf page (Deployment, node pressure, hub link)
	@printf '\n$(C)$(AR) k3s node + Deployment$(R)\n'
	@kubectl --context ubuntu-docker get node ubuntu-docker -o jsonpath='  DiskPressure={range .status.conditions[?(@.type=="DiskPressure")]}{.status}{end}{"\n"}'
	@kubectl --context ubuntu-docker --namespace ircfiber-prod get deployment/ircfiber-ircd-k8s -o wide 2>/dev/null || echo "  (no Deployment)"
	@printf '$(C)$(AR) hub links$(R)\n'
	@$(SSH) 'sudo docker exec ircfiber-ircd grep -c "k8s.ircfiber.com" /inspircd/conf/custom.conf || true; sudo docker logs --since 5m ircfiber-ircd 2>&1 | grep -c "k8s.ircfiber.com" || true'

# Every InspIRCd on the network, in link order (leaf first, then the hub that
# dials it), followed by a parity check of the server-local files that are NOT
# replicated over the server link. /RULES and the MOTD are served by
# m_showfile/m_motdpool from each server's own disk, so a file changed on one
# server alone leaves users seeing different text depending on which server
# they happen to be on. This is the target to run after editing
# roles/ircd/templates/rules.j2 — git is the source of truth for that text.
deploy-ircd-network: ## Render ircd configs on the k3s leaf AND the hub, then prove /RULES matches on both
	@$(MAKE) --no-print-directory deploy-ircd-k8s
	@$(MAKE) --no-print-directory deploy-ircd
	@$(MAKE) --no-print-directory ircd-parity

ircd-parity: ## Compare the server-local (unreplicated) ircd files across hub + leaf
	@printf '\n$(C)$(AR) /RULES parity: hub vs k3s leaf$(R)\n'
	@hub=$$($(SSH) 'sudo sha256sum /etc/ircfiber/ircd/rules.txt' | cut -d" " -f1); \
	leaf=$$(kubectl --context ubuntu-docker --namespace ircfiber-prod exec deployment/ircfiber-ircd-k8s -- sha256sum /inspircd/conf/rules.txt | cut -d" " -f1); \
	printf '  hub  %s\n  leaf %s\n' "$$hub" "$$leaf"; \
	if [ "$$hub" = "$$leaf" ]; then \
	  printf '%b\n' "$(BG)$(OK) /RULES identical on every server$(R)"; \
	else \
	  printf '%b\n' "$(Y)$(WR) /RULES DIFFERS — a user sees different rules depending on the server they land on.$(R)"; \
	  printf '%b\n' "$(Y)   An admin Config-tab edit only writes the hub; put the text in roles/ircd/templates/rules.j2 and re-run make deploy-ircd-network.$(R)"; \
	  exit 1; \
	fi

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
