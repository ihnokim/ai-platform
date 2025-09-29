#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f ".env" ]; then
  source .env
fi

if [ -f "$SCRIPT_DIR/keycloak.sh" ]; then
  echo "🔍 Loading keycloak.sh..." >&2
  source "$SCRIPT_DIR/keycloak.sh"
else
  echo "❌ $SCRIPT_DIR/keycloak.sh not found" >&2
  exit 1
fi

GITEA__URL="https://gitea.${DOMAIN_HOST}"
GITEA__ADMIN_GROUP_NAME="gitea_admin"

CLIENT_ID="gitea"
REALM_NAME="${REALM_NAME:-my-realm}"

echo "🔐 Setting up Gitea OIDC client in Keycloak ${REALM_NAME} realm..."

echo "🔧 Creating Gitea OIDC client..."
CLIENT_CONFIG='{
  "clientId": "'${CLIENT_ID}'",
  "name": "Gitea",
  "description": "OIDC client for Gitea",
  "enabled": true,
  "clientAuthenticatorType": "client-secret",
  "surrogateAuthRequired": true,
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": false,
  "publicClient": false,
  "rootUrl": "'${GITEA__URL}'",
  "adminUrl": "'${GITEA__URL}'",
  "baseUrl": "'${GITEA__URL}'",
  "redirectUris": [
      "'${GITEA__URL}'/user/oauth2/keycloak/callback"
  ],
  "webOrigins": [
      "'${GITEA__URL}'"
  ],
  "protocol": "openid-connect",
  "attributes": {
      "saml.assertion.signature": "false",
      "saml.force.post.binding": "false",
      "saml.multivalued.roles": "false",
      "saml.encrypt": "false",
      "saml.server.signature": "false",
      "saml.server.signature.keyinfo.ext": "false",
      "exclude.session.state.from.auth.response": "false",
      "saml_force_name_id_format": "false",
      "saml.client.signature": "false",
      "tls.client.certificate.bound.access.tokens": "false",
      "post.logout.redirect.uris": "'${GITEA__URL}'",
      "saml.authnstatement": "false",
      "display.on.consent.screen": "false",
      "saml.onetimeuse.condition": "false"
  },
  "authenticationFlowBindingOverrides": {},
  "fullScopeAllowed": true,
  "nodeReRegistrationTimeout": -1,
  "protocolMappers": [
      {
          "name": "username",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-usermodel-property-mapper",
          "consentRequired": false,
          "config": {
              "userinfo.token.claim": "true",
              "user.attribute": "username",
              "id.token.claim": "true",
              "access.token.claim": "true",
              "claim.name": "preferred_username",
              "jsonType.label": "String"
          }
      },
      {
          "name": "email",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-usermodel-property-mapper",
          "consentRequired": false,
          "config": {
              "userinfo.token.claim": "true",
              "user.attribute": "email",
              "id.token.claim": "true",
              "access.token.claim": "true",
              "claim.name": "email",
              "jsonType.label": "String"
          }
      },
      {
        "name": "groups",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-group-membership-mapper",
        "config": {
          "claim.name": "groups",
          "introspection.token.claim": "true",
          "full.path": "false",
          "id.token.claim": "true",
          "access.token.claim": "true",
          "userinfo.token.claim": "true",
          "lightweight.claim": "false"
        }
      },
      {
        "name": "roles",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-usermodel-client-role-mapper",
        "consentRequired": false,
        "config": {
          "introspection.token.claim": "true",
          "multivalued": "true",
          "userinfo.token.claim": "true",
          "id.token.claim": "true",
          "lightweight.claim": "false",
          "access.token.claim": "true",
          "claim.name": "roles",
          "jsonType.label": "String",
          "usermodel.clientRoleMapping.clientId": "'${CLIENT_ID}'"
        }
      }
  ],
  "defaultClientScopes": [
    "web-origins",
    "role_list",
    "profile",
    "roles",
    "email"
  ],
  "optionalClientScopes": [
    "address",
    "phone",
    "offline_access",
    "microprofile-jwt"
  ]
}'

echo "🔍 Checking for existing Gitea client..."
if client_exists "${CLIENT_ID}" "${REALM_NAME}"; then
    echo "Gitea client already exists..."
else
    echo "🆕 No existing Gitea client found"
  echo "🏗️ Creating new Gitea client..."
  if api_call POST "/admin/realms/${REALM_NAME}/clients" "$CLIENT_CONFIG" >/dev/null; then
      echo "✅ Gitea OIDC client created successfully"
  else
      echo "❌ Failed to create Gitea client"
      exit 1
  fi
fi

echo "🔐 Getting client secret..."
CLIENT_UUID=$(get_client_uuid "${CLIENT_ID}" "${REALM_NAME}")
if [ -z "$CLIENT_UUID" ]; then
    echo "❌ Failed to get client UUID"
    exit 1
fi

CLIENT_SECRET=$(api_call GET "/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/client-secret" | jq -r '.value')

echo "✅ Client secret obtained: ${CLIENT_SECRET}"

# Gitea 클라이언트 role 생성 (Gitea의 모든 권한 레벨)
echo "🎯 Creating Gitea client roles..."

# Owner role (조직 소유자 - 최고 권한)
api_call POST "/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/roles" '{
      "name": "gitea:owner",
      "description": "Gitea organization owner - full control",
      "composite": false,
      "clientRole": true
    }' >/dev/null || echo "  ⚠️  gitea:owner role already exists"

# Admin role (관리자 권한)
api_call POST "/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/roles" '{
      "name": "gitea:admin",
      "description": "Gitea admin - repository administration",
      "composite": false,
      "clientRole": true
    }' >/dev/null || echo "  ⚠️  gitea:admin role already exists"

# Write role (쓰기 권한)
api_call POST "/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/roles" '{
      "name": "gitea:write",
      "description": "Gitea write - push access",
      "composite": false,
      "clientRole": true
    }' >/dev/null || echo "  ⚠️  gitea:write role already exists"

# Read role (읽기 권한)
api_call POST "/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/roles" '{
      "name": "gitea:read",
      "description": "Gitea read - pull access only",
      "composite": false,
      "clientRole": true
    }' >/dev/null || echo "  ⚠️  gitea:read role already exists"

echo "✅ Gitea client roles created (gitea:owner, gitea:admin, gitea:write, gitea:read)"

echo ""
echo "🎉 Gitea OIDC setup completed!"
echo "📋 Configuration details:"
echo "   - Client ID: ${CLIENT_ID}"
echo "   - Client Secret: ${CLIENT_SECRET}"
echo "   - Issuer URL: ${KEYCLOAK__URL}/realms/${REALM_NAME}"
echo "   - Gitea Redirect URL: ${GITEA__URL}/user/oauth2/keycloak/callback"
echo ""
