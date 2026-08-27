# GitHub Actions deployment

The GitHub Actions workflow has two stages:

- Every pull request and push to `main` runs Ansible lint.
- A push to `main` deploys the complete stack after lint passes.
- A manual `workflow_dispatch` from `main` can deploy the stack as well.

Pull requests never connect to the servers. Production deployment is protected
by the `production` GitHub environment, so required reviewers and branch rules
can be applied before any server changes are made.

The deployment needs SSH access to the five Ubuntu hosts and an encrypted
Ansible Vault file. GitHub receives the SSH private key and Vault material as
encrypted Actions secrets; neither is committed to the repository.

The inventory uses SSH port `2222` for every host. The initial bootstrap must
be performed on port `22`; after that, CI connects to port `2222`.

## 1. Create a deployment SSH key

Create a separate Ed25519 key for this repository. Do not reuse a personal key:

```bash
ssh-keygen -t ed25519 \
  -f ~/.ssh/mysql-ha-network-github-actions \
  -C "github-actions:mysql-ha-network" \
  -N ''
```

The private key is `~/.ssh/mysql-ha-network-github-actions`. The public key is
the corresponding `.pub` file. The public key is not secret; the private key
is secret and must never be committed, pasted into an issue, or printed in CI.

The current inventory connects as `root`, so bootstrap the public key in
`/root/.ssh/authorized_keys` on each host. Verify each server fingerprint
before doing this:

```bash
cat ~/.ssh/mysql-ha-network-github-actions.pub | \
  ssh -p 2222 root@SERVER_IP 'umask 077; mkdir -p /root/.ssh; cat >> /root/.ssh/authorized_keys; chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys'
```

Repeat it for `tabriz-mysql01`, `tabriz-wg01`, `shiraz-wg02`,
`shiraz-mysql01`, and `monitor-01`. For a hardened setup, provision a
dedicated `ansible` user with narrowly scoped sudo permissions, change
`ansible_user` in `inventory/hosts.yml` to that user, and install the same
public key in that user’s `authorized_keys` instead of using root.

## 2. Create the encrypted Vault file

Create a local copy of the example, replace every placeholder with a strong,
unique value, and encrypt it:

```bash
cp inventory/group_vars/vault.yml.example /tmp/mysql-ha-vault.yml
$EDITOR /tmp/mysql-ha-vault.yml
ansible-vault encrypt /tmp/mysql-ha-vault.yml
```

The encrypted file contains the MySQL replication password, MySQL metrics
password, Grafana administrator password, and Alertmanager SMTP settings.
Store the encrypted file itself in the GitHub secret
`ANSIBLE_VAULT_FILE`; store the password used by `ansible-vault encrypt` in
`ANSIBLE_VAULT_PASSWORD`. The workflow writes both only for the duration of a
deployment and deletes them afterward.

For local deployment, use the same encrypted file as
`inventory/group_vars/vault.yml` (this path is Git-ignored):

```bash
cp /tmp/mysql-ha-vault.yml inventory/group_vars/vault.yml
ansible-playbook -i inventory/hosts.yml \
  --ask-vault-pass ansible/site.yml
```

Alternatively set `ANSIBLE_VAULT_PASSWORD_FILE` to a local password file and
run `make site`.

## 3. Add GitHub environment secrets

In the repository, open **Settings → Environments**, create an environment
named `production`, and add required reviewers and deployment branch rules.
Then add these secrets to the `production` environment under **Environment
secrets**:

| Secret | Value |
|---|---|
| `DEPLOY_SSH_PRIVATE_KEY` | Entire Ed25519 private key, including `BEGIN`/`END` lines |
| `ANSIBLE_KNOWN_HOSTS` | Verified `known_hosts` entries for all five servers |
| `ANSIBLE_VAULT_FILE` | Entire encrypted `inventory/group_vars/vault.yml` file |
| `ANSIBLE_VAULT_PASSWORD` | Password that decrypts that file |

`ANSIBLE_KNOWN_HOSTS` is not itself confidential, but it is supplied as an
environment secret so the workflow never runs an unverified `ssh-keyscan`.
Build it only after checking the server fingerprints through your cloud
console or another trusted channel:

```bash
ssh-keyscan -p 2222 -t ed25519 45.159.113.191 45.159.113.190 \
  185.213.165.112 85.208.254.172 85.208.254.233 > /tmp/mysql-ha-known_hosts
```

Inspect and verify `/tmp/mysql-ha-known_hosts` before uploading it. If a host
key changes legitimately, update the secret deliberately; do not disable
host-key checking in the workflow.

With GitHub CLI, multiline secrets can be uploaded without putting their
contents in shell history:

```bash
gh secret set --env production DEPLOY_SSH_PRIVATE_KEY \
  < ~/.ssh/mysql-ha-network-github-actions
gh secret set --env production ANSIBLE_KNOWN_HOSTS \
  < /tmp/mysql-ha-known_hosts
gh secret set --env production ANSIBLE_VAULT_FILE \
  < /tmp/mysql-ha-vault.yml
gh secret set --env production ANSIBLE_VAULT_PASSWORD
```

For the last command, paste the Vault password when prompted. Prefer the web
UI or an interactive password manager integration if your shell history policy
requires it.

## 4. Deployment behavior

After lint passes, the `production` job uses the full inventory and runs
`ansible/site.yml` in this order:

1. common Ubuntu baseline;
2. WireGuard and FRR/OSPF/BFD network;
3. MySQL and GTID replication;
4. monitoring and centralized logging.

The workflow keeps strict SSH host-key checking enabled. It does not use
`ssh-keyscan` during deployment, print private keys, or use `--diff` (which
could expose rendered secret values). Temporary SSH and Vault files are
deleted at the end of every deployment job, including failed jobs. Keep the
GitHub environment protected and rotate the deployment key, Vault password,
application passwords, and server `authorized_keys` together when access is
revoked.
