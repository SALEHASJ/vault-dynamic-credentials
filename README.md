# Dynamic Database Credentials with Vault and Terraform

Static database passwords are one of the most common security problems in production, and one of the least discussed. They live in config files, CI variables, and Slack messages. They're shared between an application, three developers, and a pipeline. Nobody rotates them, because rotation means coordinating a change across four systems and probably breaking something at 2am. And when a credential leaks, the audit trail is one shared identity, you can't tell whose it was or what used it.

This lab replaces that model. No human or service holds a database password. Instead, each identity authenticates as itself, Vault checks what that identity is allowed to do, and issues a credential that exists only for that request, expires on its own, and is traceable back to who asked for it.

## What's running



| Component | Role |
|---|---|
| Vault (Docker) | Issues credentials, enforces policy |
| PostgreSQL (Docker) | The protected resource |
| Terraform | Provisions Vault and declares the entire security posture |

## The access model

Four identities, four different levels of access, all enforced by policy rather than trust:

| Identity | Type | Can do |
|---|---|---|
| `salih` | Human  operator | Configure the database engine, read credentials |
| `eyad` | Human  developer | Read credentials from one role only |
| `brad` | Human  auditor | List what exists; cannot pull a working credential |
| `ci-pipeline` | Machine — AppRole | Read one credential path, nothing else |

## Running it

Start the containers:

```bash
docker network create vault-net

docker run -d --name vault-dev --network vault-net -p 8200:8200 \
  -e VAULT_DEV_ROOT_TOKEN_ID=myroot \
  -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
  hashicorp/vault:latest

docker run -d --name postgres-vault --network vault-net -p 5432:5432 \
  -e POSTGRES_PASSWORD=rootpassword \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_DB=demodb \
  postgres:16
```

Apply the configuration:

```bash
cd 03-vault-integration
terraform init
terraform apply
```

Thirteen resources: two auth methods, four policies, three users, one AppRole, the database engine, its connection, and the credential role.

## The demonstration

**Credentials are generated, not stored.** Request one twice:

```bash
vault read database/creds/app-role
vault read database/creds/app-role
```

Two different usernames, two different passwords, each with a one-hour lease. Neither existed before the request.

Confirm they're real Postgres users, not just Vault output:

```bash
docker exec -it postgres-vault psql -U postgres -d demodb -c "\du"
```

```
 v-token-app-role-ArHUIn3EfNa6hP94B3em-1787457789 | Password valid until 2026-08-23 05:03:14+00
 v-token-app-role-YHDk8MUs63edWufnsNyc-1787457815 | Password valid until 2026-08-23 05:03:40+00
```

Postgres itself enforces the expiry. Nothing needs to remember to clean these up.

![Terraform applying the full configuration](docs/images/terraform-apply.png)
*Thirteen resources — auth methods, policies, users, AppRole, and the database engine — created in a single apply.*

**Machines authenticate without human credentials.** The pipeline logs in with a role_id and secret_id  no password, no root token:

```bash
vault write auth/approle/login role_id=<role_id> secret_id=<secret_id>
```

It receives a 20-minute token carrying only 'pipeline-policy'. Using that token, it can read a database credential, and nothing else:

```bash
vault list auth/userpass/users
# Code: 403. permission denied
```

Least privilege isn't a claim here; it's demonstrable.

![AppRole authentication and a denied request](docs/images/approle-auth-and-denial.png)
*The pipeline authenticates with role_id and secret_id, reads a database credential, and is refused when it tries to list users.*

**Credential origin is traceable.** Generated usernames carry the auth method that requested them  `v-token-app-role-...` for a token login, `v-approle-app-role-...` for the pipeline. The audit trail is visible in the credential itself.

**Drift is detected, not discovered later.** Delete a policy by hand:

```bash
vault policy delete eyad-policy
terraform plan
```

Terraform reports the difference and restores it on the next apply. The security posture is enforced by code rather than by whoever remembers what it's supposed to look like.

![Terraform detecting a manually deleted policy](docs/images/drift-detection.png)
*A policy was deleted directly in Vault. Terraform reports the difference on the next plan.*

## How this plugs into CI

The AppRole flow is the same whether the caller is a terminal or a build runner:

```bash
# 1. Authenticate as the machine
VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id="$VAULT_ROLE_ID" secret_id="$VAULT_SECRET_ID")

# 2. Request a database credential
vault read -format=json database/creds/app-role

# 3. Use it for the job

# 4. Do nothing — the lease expires on its own
```

The pipeline holds a role_id and a secret_id. It never holds a database password.

## What a production deployment would add

This is a lab, and dev-mode Vault is deliberately not production. A real deployment needs:

- Vault in HA mode with a real storage backend and auto-unseal, not dev mode
- Remote Terraform state with locking and encryption
- Audit devices enabled and shipped to a SIEM
- Vault reachable only over TLS, on a private network
- Machine identity via a platform-native method  Kubernetes service accounts, cloud IAM, or OIDC rather than a long-lived secret_id
- Shorter TTLs tuned to actual job duration

## When not to use Vault

If you're single-cloud and entirely on managed services, native tooling is simpler and cheaper  Azure Key Vault with managed identity, or IAM database authentication on AWS, removes the credential entirely with less to operate.

Vault earns its place when the estate is mixed: multiple clouds, on-prem systems, databases and APIs that have no native identity story, and a need for one policy model and one audit log across all of them.

## Note on credentials in this repo

The token `myroot` and passwords like `salihpass` are dev-mode defaults, deliberately visible so the lab is runnable as-is. Terraform state is gitignored because it stores connection credentials in plaintext.
