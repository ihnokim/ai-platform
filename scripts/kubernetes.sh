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

KUBERNETES__URL="http://localhost:8000"

CLIENT_ID="kubernetes"
REALM_NAME="${REALM_NAME:-${KEYCLOAK__REALM_NAME}}"

echo "🔐 Setting up Kubernetes OIDC client in Keycloak ${REALM_NAME} realm..."

echo "🔧 Creating Kubernetes OIDC client..."
CLIENT_CONFIG='{
  "clientId": "'${CLIENT_ID}'",
  "name": "Kubernetes",
  "description": "OIDC client for Kubernetes",
  "enabled": true,
  "clientAuthenticatorType": "client-secret",
  "surrogateAuthRequired": true,
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": false,
  "publicClient": true,
  "rootUrl": "'${KUBERNETES__URL}'",
  "adminUrl": "'${KUBERNETES__URL}'",
  "baseUrl": "'${KUBERNETES__URL}'",
  "redirectUris": [
      "'${KUBERNETES__URL}'"
  ],
  "webOrigins": [
      "+"
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
      "post.logout.redirect.uris": "'${KUBERNETES__URL}'",
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

echo "🔍 Checking for existing Kubernetes client..."
if client_exists "${CLIENT_ID}" "${REALM_NAME}"; then
    echo "Kubernetes client already exists..."
else
    echo "🆕 No existing Kubernetes client found"
  echo "🏗️ Creating new Kubernetes client..."
  if api_call POST "/admin/realms/${REALM_NAME}/clients" "$CLIENT_CONFIG" >/dev/null; then
      echo "✅ Kubernetes OIDC client created successfully"
  else
      echo "❌ Failed to create Kubernetes client"
      exit 1
  fi
fi

echo ""
echo "🎉 Kubernetes OIDC setup completed!"
echo "📋 Configuration details:"
echo "   - Client ID: ${CLIENT_ID}"
echo "   - Issuer URL: ${KEYCLOAK__URL}/realms/${REALM_NAME}"
echo "   - Kubernetes Redirect URL: ${KUBERNETES__URL}"
echo ""
