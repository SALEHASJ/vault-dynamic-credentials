#!/bin/bash
set -e

VAULT_EXEC="docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=myroot vault-dev"

echo "==> Enabling userpass auth..."
$VAULT_EXEC vault auth enable userpass 2>/dev/null || echo "    (already enabled)"

echo "==> Writing policies..."
docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=myroot \
  vault-dev vault policy write salih-policy - <<'EOF'
path "database/creds/*" {
  capabilities = ["read"]
}
path "database/config/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "database/roles/*" {
  capabilities = ["create", "read", "update", "list"]
}
EOF

docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=myroot \
  vault-dev vault policy write eyad-policy - <<'EOF'
path "database/creds/app-role" {
  capabilities = ["read"]
}
EOF

docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=myroot \
  vault-dev vault policy write brad-policy - <<'EOF'
path "database/roles" {
  capabilities = ["list"]
}
path "sys/policies/acl" {
  capabilities = ["list"]
}
EOF

echo "==> Creating users..."
$VAULT_EXEC vault write auth/userpass/users/salih password=salihpass policies=salih-policy
$VAULT_EXEC vault write auth/userpass/users/eyad  password=eyadpass  policies=eyad-policy
$VAULT_EXEC vault write auth/userpass/users/brad  password=bradpass  policies=brad-policy

echo "==> Enabling database secrets engine..."
$VAULT_EXEC vault secrets enable database 2>/dev/null || echo "    (already enabled)"

echo "==> Configuring Postgres connection..."
$VAULT_EXEC vault write database/config/postgres-demo \
  plugin_name=postgresql-database-plugin \
  allowed_roles="app-role" \
  connection_url="postgresql://{{username}}:{{password}}@postgres-vault:5432/demodb?sslmode=disable" \
  username="postgres" \
  password="rootpassword"

echo "==> Creating app-role..."
$VAULT_EXEC vault write database/roles/app-role \
  db_name=postgres-demo \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

echo "==> Enabling AppRole auth (machine identity)..."
$VAULT_EXEC vault auth enable approle 2>/dev/null || echo "    (already enabled)"

echo "==> Writing pipeline policy..."
echo 'path "database/creds/app-role" { capabilities = ["read"] }' > /tmp/pipeline-policy.hcl
docker cp /tmp/pipeline-policy.hcl vault-dev:/tmp/pipeline-policy.hcl
$VAULT_EXEC vault policy write pipeline-policy /tmp/pipeline-policy.hcl

echo "==> Creating ci-pipeline AppRole..."
$VAULT_EXEC vault write auth/approle/role/ci-pipeline \
  token_policies="pipeline-policy" \
  token_ttl=20m \
  token_max_ttl=1h \
  secret_id_ttl=24h \
  secret_id_num_uses=0

echo ""
echo "==> AppRole credentials (machine identity):"
$VAULT_EXEC vault read auth/approle/role/ci-pipeline/role-id
$VAULT_EXEC vault write -f auth/approle/role/ci-pipeline/secret-id
echo ""
echo "==> Setup complete. Test with:"
echo "    $VAULT_EXEC vault read database/creds/app-role"
