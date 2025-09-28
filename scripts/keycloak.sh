#!/bin/bash

set -e

if [ -f ".env" ]; then
    source .env
fi

KEYCLOAK__URL="https://keycloak.${DOMAIN_HOST}"
KEYCLOAK__ADMIN_TOKEN=""
KEYCLOAK__TOKEN_EXPIRY=""

get_admin_token() {
    local keycloak_url="${1:-$KEYCLOAK__URL}"
    local admin_username="${2:-$KEYCLOAK__ADMIN_USERNAME}"
    local admin_password="${3:-$KEYCLOAK__ADMIN_PASSWORD}"
    local realm_name="${4:-$KEYCLOAK__REALM_NAME}"

    echo "🔑 Getting admin token from ${keycloak_url}..." >&2

    local token=$(curl -s -k -X POST \
        "${keycloak_url}/realms/${realm_name}/protocol/openid-connect/token" \
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

api_call() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local retry_count=0
    local max_retries=3
    local sleep_time=2

    if [[ -z "$method" ]] || [[ -z "$endpoint" ]]; then
        echo "❌ keycloak_api_call: method and endpoint are required" >&2
        return 1
    fi

    if [[ -z "$KEYCLOAK__ADMIN_TOKEN" ]]; then
        if ! get_admin_token; then
            echo "❌ Failed to obtain admin token" >&2
            return 1
        fi
    fi

    while [ $retry_count -lt $max_retries ]; do
        local temp_file=$(mktemp)
        local http_code

        if [[ -n "$data" ]]; then
            http_code=$(curl -k -s -w "%{http_code}" -o "$temp_file" \
                -X "$method" \
                -H "Authorization: Bearer $KEYCLOAK__ADMIN_TOKEN" \
                -H "Content-Type: application/json" \
                -d "$data" \
                "$KEYCLOAK__URL$endpoint")
        else
            http_code=$(curl -k -s -w "%{http_code}" -o "$temp_file" \
                -X "$method" \
                -H "Authorization: Bearer $KEYCLOAK__ADMIN_TOKEN" \
                -H "Content-Type: application/json" \
                "$KEYCLOAK__URL$endpoint")
        fi

        local body
        body=$(cat "$temp_file")
        rm -f "$temp_file"

        case $http_code in
            200|201|204)
                if [[ -n "$body" ]] && [[ "$body" != "null" ]]; then
                    echo "$body"
                fi
                return 0
                ;;
            401)
                echo "🚨 Token expired (HTTP 401), refreshing token... (attempt $((retry_count + 1))/$max_retries)"
                if get_admin_token; then
                    ((retry_count++))
                    sleep $sleep_time
                    sleep_time=$((sleep_time * 2))  # Exponential backoff
                    continue
                else
                    echo "❌ Failed to refresh token" >&2
                    return 1
                fi
                ;;
            409)
                echo "🚨 Resource already exists (HTTP 409): $(echo "$body" | jq -r '.errorMessage // .error // "Unknown error"' 2>/dev/null || echo "$body")" >&2
                return 2  # Special return code for conflicts
                ;;
            404)
                echo "🚨 Not found (HTTP 404): $(echo "$body" | jq -r '.errorMessage // .error // "Unknown error"' 2>/dev/null || echo "$body")" >&2
                return 3
                ;;
            400|500|502|503)
                local error_msg
                error_msg=$(echo "$body" | jq -r '.errorMessage // .error // "Unknown error"' 2>/dev/null || echo "$body")
                echo "❌ HTTP $http_code: $error_msg" >&2
                echo "❌ Request: $method $endpoint" >&2
                if [[ -n "$data" ]]; then
                    echo "❌ Request body: $(echo "$data" | head -3)" >&2
                fi

                if [[ $http_code =~ ^50[0-9]$ ]]; then
                    ((retry_count++))
                    if [ $retry_count -lt $max_retries ]; then
                        echo "🔄 Retrying in ${sleep_time}s... (attempt $((retry_count + 1))/$max_retries)" >&2
                        sleep $sleep_time
                        sleep_time=$((sleep_time * 2))
                        continue
                    fi
                fi
                return 1
                ;;
            *)
                echo "❌ Unexpected HTTP code $http_code: $body" >&2
                return 1
                ;;
        esac
    done

    echo "❌ Max retries ($max_retries) exceeded" >&2
    return 1
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
        "api-call")
            api_call "${2:-}" "${3:-}" "${4:-}"
            ;;
        *)
            echo "🔧 Keycloak Utility Functions" >&2
            echo "" >&2
            echo "Usage: $0 <command> [args...]" >&2
            echo "" >&2
            echo "Available commands:" >&2
            echo "  get-admin-token [keycloak_url] [admin_user] [admin_password]" >&2
            echo "  get-client-secret <client_id> [realm_name] [keycloak_url] [admin_token]" >&2
            echo "  api-call <method> <endpoint> [data]" >&2
            echo "" >&2
            echo "Environment variables:" >&2
            echo "  KEYCLOAK__URL (default: https://keycloak.platform.ai)" >&2
            echo "  KEYCLOAK__ADMIN_USERNAME (default: admin)" >&2
            echo "  KEYCLOAK__ADMIN_PASSWORD (default: string1!)" >&2
            echo "  KEYCLOAK__REALM_NAME (default: master)" >&2
            echo "" >&2
            echo "Examples:" >&2
            echo "  $0 get-admin-token" >&2
            echo "  $0 get-client-secret gitea" >&2
            echo "  $0 api-call GET /realms/master" >&2
            echo "  $0 api-call POST /realms/master '{\"realm\": \"master\"}'" >&2
            exit 1
            ;;
    esac
}

# If script is executed directly (not sourced), run main function
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
