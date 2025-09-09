#!/bin/bash

# Keycloak Utility Functions
# This script provides utility functions for Keycloak operations

set -e

# Load .env file if it exists
if [ -f ".env" ]; then
    # echo "📁 Loading .env file..." >&2
    source .env
    # echo "✅ Environment variables loaded" >&2
fi

# Default configuration
KEYCLOAK__URL="https://keycloak.${DOMAIN_HOST}"

# Function to get admin token
get_admin_token() {
    local keycloak_url="${1:-$KEYCLOAK__URL}"
    local admin_username="${2:-$KEYCLOAK__ADMIN_USERNAME}"
    local admin_password="${3:-$KEYCLOAK__ADMIN_PASSWORD}"
    local realm_name="${4:-$KEYCLOAK__REALM_NAME}"
    
    # echo "🔑 Getting admin token from ${keycloak_url}..." >&2
    
    local token=$(curl -s -k -X POST "${keycloak_url}/realms/${realm_name}/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${admin_username}" \
        -d "password=${admin_password}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" | jq -r '.access_token')
    
    if [ "$token" = "null" ] || [ -z "$token" ]; then
        echo "❌ Failed to get admin token" >&2
        return 1
    fi
    
    echo "$token"
}

# Function to get client secret by client ID
get_client_secret() {
    local client_id="$1"
    local realm_name="${2:-$KEYCLOAK__REALM_NAME}"
    local keycloak_url="${3:-$KEYCLOAK__URL}"
    local admin_token="${4:-$(get_admin_token)}"
    
    if [ -z "$client_id" ]; then
        echo "❌ Error: client_id is required" >&2
        return 1
    fi
    
    # echo "🔍 Getting client secret for client: ${client_id}..." >&2

    # Get client UUID first
    local client_uuid=$(curl -s -k -X GET "${keycloak_url}/admin/realms/${realm_name}/clients?clientId=${client_id}" \
        -H "Authorization: Bearer ${admin_token}" \
        -H "Content-Type: application/json" | jq -r '.[0].id')
    
    if [ "$client_uuid" = "null" ] || [ -z "$client_uuid" ]; then
        echo "❌ Client '${client_id}' not found in realm '${realm_name}'" >&2
        return 1
    fi
    
    # Get client secret
    local client_secret=$(curl -s -k -X GET "${keycloak_url}/admin/realms/${realm_name}/clients/${client_uuid}/client-secret" \
        -H "Authorization: Bearer ${admin_token}" \
        -H "Content-Type: application/json" | jq -r '.value')
    
    if [ "$client_secret" = "null" ] || [ -z "$client_secret" ]; then
        echo "❌ Failed to get client secret for '${client_id}'" >&2
        return 1
    fi
    
    # echo "✅ Client secret retrieved for '${client_id}'" >&2
    echo "$client_secret"
}

# Main function for command line usage
main() {
    case "${1:-}" in
        "get-admin-token")
            get_admin_token "${2:-}" "${3:-}" "${4:-}"
            ;;
        "get-client-secret")
            get_client_secret "${2:-}" "${3:-}" "${4:-}" "${5:-}"
            ;;
        *)
            echo "🔧 Keycloak Utility Functions" >&2
            echo "" >&2
            echo "Usage: $0 <command> [args...]" >&2
            echo "" >&2
            echo "Available commands:" >&2
            echo "  get-admin-token [keycloak_url] [admin_user] [admin_password]" >&2
            echo "  get-client-secret <client_id> [realm_name] [keycloak_url] [admin_token]" >&2
            echo "" >&2
            echo "Environment variables:" >&2
            echo "  KEYCLOAK__URL (default: https://keycloak.runway.ai)" >&2
            echo "  KEYCLOAK__ADMIN_USERNAME (default: admin)" >&2
            echo "  KEYCLOAK__ADMIN_PASSWORD (default: string1!)" >&2
            echo "  KEYCLOAK__REALM_NAME (default: master)" >&2
            echo "" >&2
            echo "Examples:" >&2
            echo "  $0 get-admin-token" >&2
            echo "  $0 get-client-secret gitea" >&2
            exit 1
            ;;
    esac
}

# If script is executed directly (not sourced), run main function
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
