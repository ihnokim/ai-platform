#!/bin/bash

# Check if required environment variables are set
if [ -z "$DOMAIN_HOST" ]; then
    echo "❌ Error: DOMAIN_HOST environment variable is required"
    echo "Please set DOMAIN_HOST in your .env file or export it"
    exit 1
fi

if [ -z "$ISTIO__NAMESPACE" ]; then
    echo "❌ Error: ISTIO__NAMESPACE environment variable is required"
    echo "Please set ISTIO__NAMESPACE in your .env file or export it"
    exit 1
fi

# Get Gateway IP
GATEWAY_IP=$(kubectl get svc -n ${ISTIO__NAMESPACE} istio-gateway -o jsonpath='{.spec.clusterIP}')
echo "🎯 Gateway IP: ${GATEWAY_IP}"
echo "🌐 Domain Host: ${DOMAIN_HOST}"
echo "🏗️  Istio Namespace: ${ISTIO__NAMESPACE}"

# Check if coredns-custom configmap exists
if kubectl get configmap coredns-custom -n kube-system >/dev/null 2>&1; then
    echo "🔄 Updating existing coredns-custom configmap..."
else
    echo "➕ Creating new coredns-custom configmap..."
    # Create empty configmap if it doesn't exist
    kubectl create configmap coredns-custom -n kube-system --dry-run=client -o yaml | kubectl apply -f -
fi

# Create runway-platform.server configuration with actual values
# Escape dots in domain for regex
DOMAIN_HOST_ESCAPED=$(echo "$DOMAIN_HOST" | sed 's/\./\\./g')

export DOMAIN_HOST
export DOMAIN_HOST_ESCAPED
export GATEWAY_IP
envsubst < scripts/runway-platform.server > /tmp/runway-platform.server

cat /tmp/runway-platform.server

# Merge runway-platform.server key into coredns-custom configmap
kubectl create configmap coredns-custom --from-file=runway-platform.server=/tmp/runway-platform.server -n kube-system --dry-run=client -o yaml | kubectl patch configmap coredns-custom -n kube-system --patch-file=/dev/stdin

# Clean up
rm -f /tmp/runway-platform.server

echo "✅ CoreDNS custom configuration applied successfully!"
