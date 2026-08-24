# IRC Fiber — Ansible Deployment

Enterprise-grade Ansible playbooks for deploying [IRC Fiber](https://github.com/kevinpostal/IRC_FIBER) on a single Linux host (or multi-host, for adding additional engine servers) using Docker, with Tailscale as the private mesh between hosts and Caddy for public TLS.

> **Note for ansible-core 2.20 users:** the inventory directory is no longer auto-added to `ansible_search_path` (it used to be). All playbooks here use explicit `vars_files: ["{{ playbook_dir }}/../inventories/production/group_vars/vault.yml"]` to load the encrypted vault. If you're on an older ansible-core, this still works fine.

## Architecture

```
              public internet
                     │
                     │ :80 / :443
                     ▼
              ┌──────────────┐
              │    Caddy     │  (container, host network for cert renewal)
              │  reverse     │  auto-TLS via Let's Encrypt
              │   proxy      │
              └──────┬───────┘
                     │ docker network ircfiber_net
                     ▼
              ┌──────────────┐
              │  irc-fiber   │  (gateway: HTTP + WebSocket)
              │  /app/       │
              │  irc-fiber   │
              └──────┬───────┘
                     │ Tailscale (tailscale0)
              ┌──────┴───────────────────┐
              ▼                          ▼
       ┌────────────┐             ┌────────────┐
       │   redis    │             │   mongo    │  (network_mode: host,
       │ 7-alpine   │             │  mongo:7   │   bound to tailscale IP)
       └────────────┘             └────────────┘
                                          ▲
                                          │ Tailscale
                                   ┌──────┴──────────┐
                                   │  irc-fiber-engine│ (one or more hosts)
                                   │  /app/           │
                                   │  irc-fiber-engine│
                                   └──────────────────┘
```

The gateway and engine(s) reach Mongo/Redis exclusively over the Tailscale interface.
Caddy terminates public TLS in front of the gateway.

## Layout

```
deploy/
├── ansible.cfg
├── requirements.yml
├── inventories/production/
│   ├── hosts.ini
│   ├── group_vars/
│   │   ├── all.yml             # public defaults
│   │   ├── vault.yml           # ansible-vault encrypted secrets
│   │   └── vault.example.yml   # redacted template (safe to commit)
│   └── host_vars/              # per-host overrides (engine_id, bind_address)
├── playbooks/
│   ├── site.yml                # full stack
│   ├── docker.yml              # install Docker CE
│   ├── tailscale.yml           # install + auth Tailscale
│   ├── image.yml               # build & push irc-fiber image
│   ├── mongo.yml               # deploy Mongo only
│   ├── redis.yml               # deploy Redis only
│   ├── caddy.yml               # deploy Caddy only
│   ├── gateway.yml             # deploy gateway only
│   ├── engine.yml              # deploy engine(s) only — for new engine hosts
│   ├── cloudflare.yml          # manage CF DNS records pointing at backend host(s)
│   ├── sync-db-to-tailnet.yml  # one-shot sync of local Mongo + Redis → tailnet
│   ├── firewall.yml
│   ├── update.yml              # bump image, rolling restart
│   ├── backup.yml              # mongodump + redis snapshot
│   ├── restore.yml
│   ├── restart.yml             # restart any subset
│   ├── status.yml
│   ├── logs.yml
│   ├── healthcheck.yml
│   └── prune.yml
└── roles/                      # one role per component
```

## Prerequisites

- A Debian/Ubuntu LTS host (or VM on GCP / any other cloud).
- A DNS A/AAAA record for `ircfiber_domain` pointing at the host's public IP.
- A Tailscale account; create a reusable auth key tagged `tag:ircfiber` at <https://login.tailscale.com/admin/settings/keys>.
- A Docker registry (Docker Hub free tier, GitHub Container Registry, or private). Set `docker_registry_url` in `group_vars/all.yml`.
- An Ansible control machine (laptop, CI runner) with `ansible-core` ≥ 2.14. **The control node must be able to reach target hosts by their Tailscale name or 100.x.x.x IP** — either join the same tailnet, or run `tailscaled` locally with `--accept-routes`.

> **Important:** rename the Tailscale device to something stable (e.g. `ircfiber-prod-1`) before adding it to your inventory. The random `izt4n520nxas8w06c5zfc9z.tail544547.ts.net` names change whenever the host re-registers, and they leak your tailnet ID. Run `ssh root@HOST tailscale set --hostname=ircfiber-prod-1` once.

## First-time setup

```bash
# 1. Install collections
cd deploy
ansible-galaxy collection install -r requirements.yml

# 2. Edit non-sensitive defaults
$EDITOR inventories/production/group_vars/all.yml

# 3. Create the encrypted vault
cp inventories/production/group_vars/vault.example.yml \
   inventories/production/group_vars/vault.yml
$EDITOR inventories/production/group_vars/vault.yml   # fill in real values
ansible-vault encrypt inventories/production/group_vars/vault.yml

# 4. Rename the Tailscale device to a stable, human-readable name
#    (random MagicDNS names like 'izt4n520nxas8w06c5zfc9z.tail544547.ts.net'
#     change if the host ever re-registers, which would silently break
#     your inventory. Tailnet IDs also leak the org's Tailscale account.)
ssh root@<host> tailscale set --hostname=ircfiber-prod-1

# 5. Edit the inventory to use the new hostname
$EDITOR inventories/production/hosts.ini

# 6. Verify you can reach the host by its Tailscale name
#    (your control node must be on the same tailnet, or use the
#    100.x.x.x IP directly)
ssh deploy@ircfiber-prod-1    # should fail — user doesn't exist yet

# 7. Bootstrap: create the non-root 'deploy' user
#    IMPORTANT: use `-e ansible_user=root`, not `--user root`.
#    In ansible-core 2.20+, inventory's `ansible_user=deploy` overrides
#    the CLI `--user` flag, so the playbook would still try to connect
#    as `deploy` (who doesn't exist yet). `-e ansible_user=root` is the
#    only CLI override that has higher precedence than inventory.
ansible-playbook playbooks/bootstrap.yml -e ansible_user=root

# 8. Test connectivity as the deploy user
ansible ircfiber -m ping

# 9. Deploy everything
ansible-playbook playbooks/site.yml
```

### Adding a new engine host

Repeat the bootstrap for the new host, then add it to the inventory:

```bash
# On the new host
ssh root@newengine tailscale set --hostname=ircfiber-prod-2
ssh root@newengine    # or use the Tailscale IP

# From the control node
ansible-playbook playbooks/bootstrap.yml -e ansible_user=root -l ircfiber-prod-2

# Update the inventory
$EDITOR inventories/production/hosts.ini    # append to [ircfiber_engines]

# Deploy only the engine on the new host
ansible-playbook playbooks/engine.yml -l ircfiber-prod-2
```

The gateway sees the new engine register via heartbeat in <10s and starts
assigning networks to it. No gateway changes required.

## Day-to-day operations

```bash
# ── Code deploys ──────────────────────────────────────────────────────
# Fast incremental binary deploy (daily use):
make update                     # rsync + BuildKit → restart engine + gateway

# Engine deploys are hard restart (brief disconnect, auto-reconnect). Handoff removed 2026-08-08.
# See AGENTS.md Engine Lifecycle. Do not reintroduce SCM_RIGHTS / IRCFIBER_RELOAD_FROM_PID.
make handoff                    # REMOVED — now hard restart (see above)
make handoff-backup             # REMOVED

# Full image rebuild (Containerfile from scratch):
make update-full                # alias: make deploy

# Frontend / gateway-only deploys (engine untouched — no IRC disconnect):
make update-assets              # EPHEMERAL — pushes public/dist via docker exec
                                #  ~2-3s, no restart, survives `docker restart`
                                #  but LOST on `docker rm` / `docker compose up --force-recreate`
                                #  or host reboot. Use for quick iteration only.
make update-gateway             # PERSISTENT — rebuilds gateway image on host
                                #  then recreates ircfiber-gateway via Ansible.
                                #  Engine (ircfiber-engine-ovh) NOT restarted.
                                #  ~2-3 min first time, cached after. Survives
                                #  container recreate and host reboot. Use for
                                #  any frontend/assets change you want to keep.

# ── Component management ──────────────────────────────────────────────
# Deploy/redeploy a single component
ansible-playbook playbooks/mongo.yml
ansible-playbook playbooks/redis.yml
ansible-playbook playbooks/gateway.yml
ansible-playbook playbooks/caddy.yml
ansible-playbook playbooks/engine.yml
```

> **Gateway SPA gotcha (2026-08-09):** `public/` and `backend/views/index.dt`
> are **baked into the gateway image** at build time (`Containerfile`
> `COPY public/ ./public/`). `make update-assets` writes to the **running**
> container's writable layer via `docker exec tar` — it survives
> `docker restart` but is **discarded** on `docker rm -f ircfiber-gateway`
> or `docker compose up --force-recreate` / host reboot, reverting the SPA
> to the old image. `2026-08-09` incident: a frontend deploy via
> `update-assets` + manual `docker rm` + `compose up` wiped the new
> `main-S6NCrGWT.js` (BLCKND/SUPERNETS), leaving the SPA 404.
> **Fix:** `make update-assets` now also `rsync`s to
> `/opt/ircfiber-src/public/` on the host so the next image build has the
> assets, and `make update-gateway` was added for a persistent gateway-only
> deploy (frontend → rsync → `docker build --target runtime-gateway` →
> `ansible-playbook playbooks/gateway.yml` — engine untouched).


### Engine deploy (hard restart)

Engine deploys use hard restart (`docker restart ircfiber-engine-ovh`).
IRC connections briefly disconnect and auto-reconnect via backoff.
`SCM_RIGHTS` handoff (`/tmp/ircfiber-handoff-<serverId>.sock`,
`IRCFIBER_RELOAD_FROM_PID`) was removed 2026-08-08 as legacy — see
`AGENTS.md#Engine Lifecycle` and `engine/source/ircfiber/engine/handoff.d`
(deprecated stub).

```
make update   # gateway+engine hard restart
```

What happens (hard restart):
1. Builds the new engine binary via BuildKit (same as `make update`)
2. Copies the new binary into the running container as `/app/irc-fiber-engine`
3. Restarts the container (`docker restart ircfiber-engine-ovh`) — brief IRC
   disconnect, auto-reconnect via engine backoff loop. DM/channel scrollback
   survives via `storage/buffer.d` (30-day `scrollback:` keys, not FD transfer).

TLS connections soft-reconnect (1-2s CAP/SASL/JOIN); plain TCP also reconnects
(previously zero-disconnect via `SCM_RIGHTS`, now same as TLS).

The first run takes ~80-90s (BuildKit build). Subsequent runs take 5-15s
(incremental recompilation via Dockers' dub cache mount).

```bash
# Deploy/redeploy a single component

# Add a new engine host on a new VM
# 1. apt-install baseline; add to [ircfiber_engines] in hosts.ini
# 2. Bootstrap:
ansible-playbook playbooks/docker.yml   -l newengine.example.com
ansible-playbook playbooks/tailscale.yml -l newengine.example.com
ansible-playbook playbooks/engine.yml   -l newengine.example.com
# The gateway sees the new engine register in <10s (one heartbeat).

# Update to a new image version
ansible-playbook playbooks/update.yml -e ircfiber_version=0.4.0

# Status & logs
ansible-playbook playbooks/status.yml
ansible-playbook playbooks/logs.yml -e component=gateway tail=200
ansible-playbook playbooks/healthcheck.yml

# Restart a component
ansible-playbook playbooks/restart.yml -e components=gateway,engine

# Backup / restore
ansible-playbook playbooks/backup.yml
ansible-playbook playbooks/restore.yml -e snapshot=mongo-20251201-120000.archive

# Prune old images (keeps 3 newest tags)
ansible-playbook playbooks/prune.yml
```

## Pre-flight validation

The SigNoz role runs a local ClickHouse config validator before
touching the host. This catches the class of bug that puts the
clickhouse container into a restart loop on the live server (e.g.
pool-size / mutation-defaults underflow) and would otherwise take
30+ minutes to surface as a 728 MB `err.log` filling the writable
layer.

```bash
# Run the validator directly (any time)
./deploy/test/signoz-config/test-clickhouse-config.sh

# Run the full regression suite against known-bad fixtures
./deploy/test/signoz-config/test-clickhouse-config-regressions.sh
```

See [`deploy/test/signoz-config/README.md`](test/signoz-config/README.md)
for the full rationale and what's tested.

## Secrets

All sensitive values live in `inventories/production/group_vars/vault.yml`, encrypted with `ansible-vault`. The `.example.yml` file is a redacted template committed for onboarding. The Ansible control node decrypts the vault at runtime with the password you set.

```bash
# Edit vault
ansible-vault edit inventories/production/group_vars/vault.yml

# Or use a password file
echo "my-vault-pass" > ~/.vault_pass.txt
chmod 600 ~/.vault_pass.txt
ansible-playbook playbooks/site.yml --vault-password-file ~/.vault_pass.txt
```

### Cloudflare DNS

If your public-facing domain is registered on Cloudflare, the `cloudflare` role can manage the A records for you so the domain resolves to the backend host's public IP (the same role that wires Let's Encrypt challenges to that host via Caddy).

```bash
# 1. Create a scoped API token at https://dash.cloudflare.com/profile/api-tokens
#    Permission: Zone:DNS:Edit (scoped to the zone that owns the domain).
#    Copy the account ID from the dashboard sidebar on any zone page.

# 2. Store the token + account ID in the encrypted vault
ansible-vault edit inventories/production/group_vars/vault.yml
#   vault_cloudflare_api_token:    "cfat_..."
#   vault_cloudflare_account_id:   "1389bd41e95b9a1d98085904980be87f"

# 3. Tell the role which zone to manage and which public IP to point at
$EDITOR inventories/production/group_vars/all.yml
#   cloudflare_zone: "your-domain.com"
$EDITOR inventories/production/host_vars/<hostname>.yml
#   cloudflare_target_ip: "47.236.247.169"

# 4. Make sure the zone's nameservers are delegated to Cloudflare
#    (otherwise records created here won't resolve publicly).

# 5. Run (idempotent — safe to re-run)
ansible-playbook playbooks/cloudflare.yml

# Or let site.yml do it automatically as part of the full deploy.
```

The role manages apex (`@`) and `www` records by default; override `cloudflare_record_prefixes` in `group_vars/all.yml` (or set `cloudflare_records` directly per host) to manage a different set. `cloudflare_proxied: true` flips CF into "orange cloud" mode (CF proxies traffic and terminates TLS at the edge); `false` keeps CF as authoritative DNS only.

## Tailscale ACL recommendation

In the Tailscale admin console → ACLs, restrict the `ircfiber` tag to:

```jsonc
{
  "acls": [
    { "action": "accept", "src": ["tag:ircfiber"], "dst": ["tag:ircfiber:6379", "tag:ircfiber:27017", "tag:ircfiber:8091"] }
  ],
  "tagOwners": { "tag:ircfiber": ["autogroup:admin"] }
}
```

This ensures even if a host is compromised, it can only reach Redis/Mongo/engine-admin on other ircfiber-tagged devices, not the broader tailnet.

## Customizing

All knobs are in `inventories/production/group_vars/all.yml`. Override per host with `inventories/production/host_vars/<hostname>.yml`.

## CI: ansible-lint

```bash
pip install ansible-lint
ansible-lint
```

## License

MIT — same as IRC Fiber.
