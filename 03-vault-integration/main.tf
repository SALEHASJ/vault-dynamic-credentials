terraform {
  required_version = ">= 1.5"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

provider "vault" {
  address = "http://localhost:8200"
  token   = "myroot"
}

# ---------- Auth methods ----------

resource "vault_auth_backend" "userpass" {
  type = "userpass"
}

resource "vault_auth_backend" "approle" {
  type = "approle"
}

# ---------- Policies ----------

resource "vault_policy" "salih" {
  name = "salih-policy"

  policy = <<EOT
path "database/creds/*" {
  capabilities = ["read"]
}
path "database/config/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "database/roles/*" {
  capabilities = ["create", "read", "update", "list"]
}
EOT
}

resource "vault_policy" "eyad" {
  name = "eyad-policy"

  policy = <<EOT
path "database/creds/app-role" {
  capabilities = ["read"]
}
EOT
}

resource "vault_policy" "brad" {
  name = "brad-policy"

  policy = <<EOT
path "database/roles" {
  capabilities = ["list"]
}
path "sys/policies/acl" {
  capabilities = ["list"]
}
EOT
}

resource "vault_policy" "pipeline" {
  name = "pipeline-policy"

  policy = <<EOT
path "database/creds/app-role" {
  capabilities = ["read"]
}
EOT
}

# ---------- Human users ----------

resource "vault_generic_endpoint" "salih" {
  depends_on           = [vault_auth_backend.userpass]
  path                 = "auth/userpass/users/salih"
  ignore_absent_fields = true

  data_json = jsonencode({
    password = "salihpass"
    policies = "salih-policy"
  })
}

resource "vault_generic_endpoint" "eyad" {
  depends_on           = [vault_auth_backend.userpass]
  path                 = "auth/userpass/users/eyad"
  ignore_absent_fields = true

  data_json = jsonencode({
    password = "eyadpass"
    policies = "eyad-policy"
  })
}

resource "vault_generic_endpoint" "brad" {
  depends_on           = [vault_auth_backend.userpass]
  path                 = "auth/userpass/users/brad"
  ignore_absent_fields = true

  data_json = jsonencode({
    password = "bradpass"
    policies = "brad-policy"
  })
}

# ---------- Machine identity ----------

resource "vault_approle_auth_backend_role" "ci_pipeline" {
  backend        = vault_auth_backend.approle.path
  role_name      = "ci-pipeline"
  token_policies = ["pipeline-policy"]

  token_ttl          = 1200
  token_max_ttl      = 3600
  secret_id_ttl      = 86400
  secret_id_num_uses = 0
}

# ---------- Database secrets engine ----------

resource "vault_mount" "db" {
  path = "database"
  type = "database"
}

resource "vault_database_secret_backend_connection" "postgres" {
  backend       = vault_mount.db.path
  name          = "postgres-demo"
  allowed_roles = ["app-role"]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@postgres-vault:5432/demodb?sslmode=disable"
    username       = "postgres"
    password       = "rootpassword"
  }
}

resource "vault_database_secret_backend_role" "app_role" {
  backend = vault_mount.db.path
  name    = "app-role"
  db_name = vault_database_secret_backend_connection.postgres.name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"
  ]

  default_ttl = 3600
  max_ttl     = 86400
}

# ---------- Outputs ----------

output "approle_role_id" {
  value       = vault_approle_auth_backend_role.ci_pipeline.role_id
  description = "Machine identity role_id for the CI pipeline"
}