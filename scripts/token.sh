#!/usr/bin/env bash

set -euo pipefail

# 인증서를 환경 변수로 지정 (self-signed 테스트용) e.g. root-ca.pem
export SSL_CERT_FILE="${SSL_CERT_FILE:-$(pwd)/certs/ai-platform-cert.pem}"

DOMAIN_HOST="${DOMAIN_HOST:-platform.ai}"
INSECURE="${INSECURE:-false}"
REALM_NAME="${REALM_NAME:-my-realm}"
CLIENT_ID="${CLIENT_ID:-my-client-id}"
CLIENT_SECRET="${CLIENT_SECRET:-my-client-secret}"
USERNAME="${USERNAME:-my-username}"
PASSWORD="${PASSWORD:-my-password}"

CURL_OPTS=("-sS")
if [ "$INSECURE" = "true" ]; then
  CURL_OPTS+=("-k")
fi

RESPONSE=$(curl "${CURL_OPTS[@]}" \
  -X POST \
  -d "client_id=${CLIENT_ID}" \
  -d "username=${USERNAME}" \
  -d "password=${PASSWORD}" \
  -d "grant_type=password" \
  -d "client_secret=${CLIENT_SECRET}" \
  "https://keycloak.${DOMAIN_HOST}/realms/${REALM_NAME}/protocol/openid-connect/token")

if command -v jq >/dev/null 2>&1; then
  echo "$RESPONSE" | jq .
else
  echo "$RESPONSE"
fi

if command -v jq >/dev/null 2>&1; then
  ACCESS_TOKEN=$(echo "$RESPONSE" | jq -r .access_token)
else
  ACCESS_TOKEN=$(echo "$RESPONSE" | sed -n 's/.*"access_token"\s*:\s*"\([^"]*\)".*/\1/p')
fi

if [ -z "${ACCESS_TOKEN:-}" ] || [ "$ACCESS_TOKEN" = "null" ]; then
  echo "⚠️  access_token을 가져오지 못했습니다. 위의 응답을 확인하세요." >&2
  exit 1
fi

echo "=== Access Token (JWT) ==="
echo "$ACCESS_TOKEN"

b64url_decode() {
  local input="$1"
  # URL-safe → 표준 base64
  input="${input//-/+}"
  input="${input//_//}"
  # padding 보정
  local mod=$(( ${#input} % 4 ))
  if [ $mod -eq 2 ]; then input="${input}=="; fi
  if [ $mod -eq 3 ]; then input="${input}="; fi
  if [ $mod -eq 1 ]; then input="${input}A==="; fi
  # decode (GNU base64 or macOS base64)
  if base64 --help 2>/dev/null | grep -q -- "--decode"; then
    echo -n "$input" | base64 --decode 2>/dev/null
  else
    echo -n "$input" | base64 -D 2>/dev/null
  fi
}

# JWT는 header.payload.signature 구조니까 payload만 꺼내고 디코딩
PAYLOAD_B64=$(echo "$ACCESS_TOKEN" | cut -d "." -f2)
CLAIMS_JSON=$(b64url_decode "$PAYLOAD_B64" || true)

echo "=== Decoded Payload (Claims) ==="
if [ -n "$CLAIMS_JSON" ]; then
  if command -v jq >/dev/null 2>&1; then
    echo "$CLAIMS_JSON" | jq .
  else
    echo "$CLAIMS_JSON"
  fi
else
  echo "⚠️  JWT payload 디코딩에 실패했습니다." >&2
fi
