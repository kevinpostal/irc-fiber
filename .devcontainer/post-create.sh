#!/usr/bin/env bash
set -e
echo "IRC Fiber post-create: submodules + 1Password -> vault"
# 1. Submodules (superproject)
if [ -f .gitmodules ]; then
  git submodule update --init --recursive
fi
# 2. 1Password -> vault (if op CLI available and not in CI)
if command -v op >/dev/null 2>&1 && [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  echo "1Password CLI detected, injecting vault..."
  op inject -i deploy/inventories/production/group_vars/vault.example.yml -o deploy/inventories/production/group_vars/vault.yml || true
  op read "op://IRC Fiber/vault/password" > deploy/.vault_pass.txt 2>/dev/null || true
  for d in site engine; do
    if [ -d "$d/deploy" ]; then
      op inject -i "$d/deploy/inventories/production/group_vars/vault.example.yml" -o "$d/deploy/inventories/production/group_vars/vault.yml" 2>/dev/null || true
      op read "op://IRC Fiber/vault/password" > "$d/deploy/.vault_pass.txt" 2>/dev/null || true
    fi
  done
fi
# 3. Fallback: Codespaces secret -> .vault_pass.txt
if [ -n "${ANSIBLE_VAULT_PASSWORD:-}" ] && [ ! -s deploy/.vault_pass.txt ]; then
  echo "$ANSIBLE_VAULT_PASSWORD" > deploy/.vault_pass.txt
  mkdir -p site/deploy engine/deploy 2>/dev/null || true
  echo "$ANSIBLE_VAULT_PASSWORD" > site/deploy/.vault_pass.txt 2>/dev/null || true
  echo "$ANSIBLE_VAULT_PASSWORD" > engine/deploy/.vault_pass.txt 2>/dev/null || true
  echo "Wrote vault password from Codespaces secret"
fi
echo "post-create done. Run: cd site && npm --prefix frontend ci && docker compose up -d"
